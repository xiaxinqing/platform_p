#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "../../native/pjsip_service.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kPjsipChannelName[] = "platform_p/pjsip";

FlValue* pjsip_result_value(const platform_p::PjsipResult& result) {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "success",
                           fl_value_new_bool(result.success));
  fl_value_set_string_take(value, "state",
                           fl_value_new_string(result.state.c_str()));
  fl_value_set_string_take(value, "status",
                           fl_value_new_int(result.status));
  fl_value_set_string_take(value, "message",
                           fl_value_new_string(result.message.c_str()));
  return value;
}

FlValue* pjsip_event_value(const platform_p::PjsipEvent& event) {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "type",
                           fl_value_new_string(event.type.c_str()));
  fl_value_set_string_take(value, "state",
                           fl_value_new_string(event.state.c_str()));
  fl_value_set_string_take(value, "level",
                           fl_value_new_int(event.level));
  fl_value_set_string_take(value, "message",
                           fl_value_new_string(event.message.c_str()));
  return value;
}

struct PjsipNotification {
  FlMethodChannel* channel;
  platform_p::PjsipEvent event;
};

gboolean invoke_pjsip_event(gpointer user_data) {
  auto* notification = static_cast<PjsipNotification*>(user_data);
  g_autoptr(FlValue) value = pjsip_event_value(notification->event);
  fl_method_channel_invoke_method(notification->channel, "event", value,
                                  nullptr, nullptr, nullptr);
  g_object_unref(notification->channel);
  delete notification;
  return G_SOURCE_REMOVE;
}

void notify_pjsip_event(FlMethodChannel* channel,
                        const platform_p::PjsipEvent& event) {
  if (channel == nullptr) {
    return;
  }
  auto* notification =
      new PjsipNotification{FL_METHOD_CHANNEL(g_object_ref(channel)), event};
  g_idle_add(invoke_pjsip_event, notification);
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* pjsip_channel;
  platform_p::PjsipService* pjsip_service;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void pjsip_method_call_cb(FlMethodChannel*,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  platform_p::PjsipResult result;

  if (g_strcmp0(method, "initialize") == 0) {
    result = self->pjsip_service->Initialize();
  } else if (g_strcmp0(method, "status") == 0) {
    result = self->pjsip_service->GetStatus();
  } else if (g_strcmp0(method, "shutdown") == 0) {
    result = self->pjsip_service->Shutdown();
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  g_autoptr(FlValue) value = pjsip_result_value(result);
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(method_call, response, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "platform_p");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "platform_p");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  FlPluginRegistrar* pjsip_registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "PlatformPPjsip");
  g_autoptr(FlStandardMethodCodec) pjsip_codec =
      fl_standard_method_codec_new();
  self->pjsip_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(pjsip_registrar),
      kPjsipChannelName, FL_METHOD_CODEC(pjsip_codec));
  self->pjsip_service = new platform_p::PjsipService();
  self->pjsip_service->SetEventCallback(
      [channel = self->pjsip_channel](const platform_p::PjsipEvent& event) {
        notify_pjsip_event(channel, event);
      });
  fl_method_channel_set_method_call_handler(
      self->pjsip_channel, pjsip_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->pjsip_service != nullptr) {
    self->pjsip_service->Shutdown();
  }

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->pjsip_service != nullptr) {
    self->pjsip_service->SetEventCallback(nullptr);
    delete self->pjsip_service;
    self->pjsip_service = nullptr;
  }
  g_clear_object(&self->pjsip_channel);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
