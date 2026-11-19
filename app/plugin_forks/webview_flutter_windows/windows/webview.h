#pragma once

#include <WebView2.h>
#include <wil/com.h>
#include <windows.ui.composition.desktop.h>
#include <windows.ui.composition.h>
#include <winrt/base.h>

#include <functional>
#include <string>
#include <vector>

#include "util/surface_geometry.h"

class WebviewHost;

enum class WebviewLoadingState { None, Loading, NavigationCompleted };

enum class WebviewPointerButton { None, Primary, Secondary, Tertiary };

enum class WebviewPointerEventKind { Activate, Down, Enter, Leave, Up, Update };

enum class WebviewDownloadEventKind {
  DownloadStarted,
  DownloadCompleted,
  DownloadProgress
};

enum class WebviewPermissionKind {
  Unknown,
  Microphone,
  Camera,
  GeoLocation,
  Notifications,
  OtherSensors,
  ClipboardRead
};

enum class WebviewPermissionState { Default, Allow, Deny };

enum class WebviewPopupWindowPolicy { Allow, Deny, ShowInSameWindow };

enum class WebviewHostResourceAccessKind { Deny, Allow, DenyCors };

struct WebviewHistoryChanged {
  BOOL can_go_back;
  BOOL can_go_forward;
};

// Mirrors ICoreWebView2Cookie. |expires| is in seconds since the UNIX epoch,
// or -1 for session cookies. |same_site| carries the
// COREWEBVIEW2_COOKIE_SAME_SITE_KIND value (None=0, Lax=1, Strict=2), which
// the Dart side decodes as an enum index.
struct WebviewCookie {
  std::string name;
  std::string value;
  std::string domain;
  std::string path;
  double expires = -1.0;
  bool is_secure = false;
  bool is_http_only = false;
  bool is_session = true;
  int same_site = 1;
};

struct WebviewDownloadEvent {
  WebviewDownloadEventKind kind;
  std::string url;
  std::string resultFilePath;
  INT64 bytesReceived;
  INT64 totalBytesToReceive;
};

struct VirtualKeyState {
 public:
  inline void set_isLeftButtonDown(bool is_down) {
    set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_LEFT_BUTTON,
        is_down);
  }

  inline void set_isRightButtonDown(bool is_down) {
    set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_RIGHT_BUTTON,
        is_down);
  }

  inline void set_isMiddleButtonDown(bool is_down) {
    set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_MIDDLE_BUTTON,
        is_down);
  }

  inline COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS state() const { return state_; }

 private:
  COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS state_ =
      COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS::
          COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE;

  inline void set(COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS key, bool flag) {
    if (flag) {
      state_ |= key;
    } else {
      state_ &= ~key;
    }
  }
};

struct EventRegistrations {
  EventRegistrationToken basic_authentication_requested_token_{};
  EventRegistrationToken source_changed_token_{};
  EventRegistrationToken content_loading_token_{};
  EventRegistrationToken navigation_completed_token_{};
  EventRegistrationToken history_changed_token_{};
  EventRegistrationToken document_title_changed_token_{};
  EventRegistrationToken cursor_changed_token_{};
  EventRegistrationToken got_focus_token_{};
  EventRegistrationToken lost_focus_token_{};
  EventRegistrationToken move_focus_requested_token_{};
  EventRegistrationToken web_message_received_token_{};
  EventRegistrationToken permission_requested_token_{};
  EventRegistrationToken devtools_protocol_event_token_{};
  EventRegistrationToken file_chooser_opened_token_{};
  EventRegistrationToken new_windows_requested_token_{};
  EventRegistrationToken contains_fullscreen_element_changed_token_{};
  EventRegistrationToken download_starting_token_{};
  EventRegistrationToken download_bytes_received_token_{};
  EventRegistrationToken download_state_changed_token_{};
};

class Webview {
 public:
  friend class WebviewHost;

  typedef std::function<void(const std::string&)> UrlChangedCallback;
  typedef std::function<void(WebviewLoadingState)> LoadingStateChangedCallback;
  typedef std::function<void(COREWEBVIEW2_WEB_ERROR_STATUS)>
      OnLoadErrorCallback;
  typedef std::function<void(WebviewHistoryChanged)> HistoryChangedCallback;
  typedef std::function<void(const std::string&)> DevtoolsProtocolEventCallback;
  typedef std::function<void(const std::string&)> DocumentTitleChangedCallback;
  typedef std::function<void(size_t width, size_t height)>
      SurfaceSizeChangedCallback;
  typedef std::function<void(const HCURSOR)> CursorChangedCallback;
  typedef std::function<void(bool)> FocusChangedCallback;
  typedef std::function<void(bool, const std::string&)>
      AddScriptToExecuteOnDocumentCreatedCallback;
  typedef std::function<void(bool, const std::string&)> ScriptExecutedCallback;
  typedef std::function<void(const std::string&)> WebMessageReceivedCallback;
  typedef std::function<void(WebviewPermissionState state)>
      WebviewPermissionRequestedCompleter;
  typedef std::function<void(const std::string& url, WebviewPermissionKind kind,
                             bool is_user_initiated,
                             WebviewPermissionRequestedCompleter completer)>
      PermissionRequestedCallback;
  typedef std::function<void(bool contains_fullscreen_element)>
      ContainsFullScreenElementChangedCallback;
  typedef std::function<void(WebviewDownloadEvent)> DownloadEventCallback;
  typedef std::function<void(bool success, std::vector<WebviewCookie> cookies)>
      GetCookiesCallback;
  // dsh-go: WebView2 has no file-chooser event; CDP Page.fileChooserOpened is
  // intercepted instead. mode: 0 = single, 1 = multiple. |node_json| is the
  // DOM.describeNode reply (empty when it could not be read), so the Dart side
  // can honour the element's accept attribute.
  typedef std::function<void(int mode, const std::string& backend_node_id,
                             const std::string& node_json)>
      FileChooserRequestedCallback;

  // dsh-go: HTTP Basic credentials supplied ahead of a navigation. Filled at
  // BasicAuthenticationRequested time; never placed in the URL.
  struct BasicAuthCredential {
    std::string host;
    std::string username;
    std::string password;
  };

  ~Webview();

  ABI::Windows::UI::Composition::IVisual* const surface() {
    return surface_.get();
  }

  bool IsValid() { return is_valid_; }

  // Applies |geometry| (see util/surface_geometry.h): the composition surface
  // and rasterization scale follow its extent, the Bounds origin follows its
  // offset. A call that changes neither is a no-op, and a change of offset
  // alone only moves the bounds, so the widget can report its position every
  // frame while scrolling or animating without the texture being rebuilt.
  void SetSurfaceSize(const util::SurfaceGeometry& geometry);

  // Tells WebView2 that an ancestor window moved. Required for accessibility
  // and for dialogs and popups to stay anchored while they are open, because
  // WebView2 caches the parent window's screen position.
  void NotifyParentWindowMoved();
  void SetCursorPos(double x, double y);
  void SetPointerUpdate(int32_t pointer, WebviewPointerEventKind eventKind,
                        double x, double y, double size, double pressure);
  void SetPointerButtonState(WebviewPointerButton button, bool isDown);
  void SetScrollDelta(double delta_x, double delta_y);
  void LoadUrl(const std::string& url);
  void LoadStringContent(const std::string& content);
  bool Stop();
  bool Reload();
  bool GoBack();
  bool GoForward();
  void AddScriptToExecuteOnDocumentCreated(
      const std::string& script,
      AddScriptToExecuteOnDocumentCreatedCallback callback);
  void RemoveScriptToExecuteOnDocumentCreated(const std::string& script_id);
  void ExecuteScript(const std::string& script,
                     ScriptExecutedCallback callback);
  bool PostWebMessage(const std::string& json);
  // |uri| may be empty to request all cookies of the profile.
  void GetCookies(const std::string& uri, GetCookiesCallback callback);
  bool SetCookie(const WebviewCookie& cookie);
  // Deletes cookies named |name| under |uri| (all domains/paths when |uri|
  // is empty).
  bool DeleteCookies(const std::string& name, const std::string& uri);
  bool ClearCookies();
  bool ClearCache();
  bool SetCacheDisabled(bool disabled);
  void SetPopupWindowPolicy(WebviewPopupWindowPolicy policy);
  bool SetDefaultContextMenusEnabled(bool enabled);
  bool SetUserAgent(const std::string& user_agent);
  bool SetDevToolsEnabled(bool enabled);
  bool OpenDevTools();
  bool SetBackgroundColor(int32_t color);
  bool SetZoomControlEnabled(bool enabled);
  bool SetZoomFactor(double factor);
  bool Suspend();
  bool Resume();
  bool MoveFocus();

  // dsh-go: set (or clear, with empty strings) the credential used to answer
  // HTTP Basic challenges. Only challenges whose Uri host equals |host| are
  // answered; all others are cancelled so credentials never cross origins.
  void SetBasicAuth(const std::string& host, const std::string& username,
                    const std::string& password);

  // dsh-go: file chooser interception via CDP.
  void SetFileChooserInterceptionEnabled(bool enabled);
  void SetFileInputFiles(const std::string& backend_node_id,
                         const std::vector<std::string>& paths);
  // Dismisses an intercepted chooser so the page sees a cancel instead of a
  // file input that never answers.
  void CancelFileChooser(const std::string& backend_node_id);

  bool SetVirtualHostNameMapping(const std::string& hostName,
                                 const std::string& path,
                                 WebviewHostResourceAccessKind accessKind);
  bool ClearVirtualHostNameMapping(const std::string& hostName);

  void UpdateDownloadProgress(ICoreWebView2DownloadOperation* download);

  void OnUrlChanged(UrlChangedCallback callback) {
    url_changed_callback_ = std::move(callback);
  }

  void OnLoadError(OnLoadErrorCallback callback) {
    on_load_error_callback_ = std::move(callback);
  }

  void OnLoadingStateChanged(LoadingStateChangedCallback callback) {
    loading_state_changed_callback_ = std::move(callback);
  }

  void OnDownloadEvent(DownloadEventCallback callback) {
    download_event_callback_ = std::move(callback);
  }

  void OnHistoryChanged(HistoryChangedCallback callback) {
    history_changed_callback_ = std::move(callback);
  }

  void OnSurfaceSizeChanged(SurfaceSizeChangedCallback callback) {
    surface_size_changed_callback_ = std::move(callback);
  }

  void OnDocumentTitleChanged(DocumentTitleChangedCallback callback) {
    document_title_changed_callback_ = std::move(callback);
  }

  void OnCursorChanged(CursorChangedCallback callback) {
    cursor_changed_callback_ = std::move(callback);
  }

  void OnFocusChanged(FocusChangedCallback callback) {
    focus_changed_callback_ = std::move(callback);
  }

  void OnWebMessageReceived(WebMessageReceivedCallback callback) {
    web_message_received_callback_ = std::move(callback);
  }

  void OnPermissionRequested(PermissionRequestedCallback callback) {
    permission_requested_callback_ = std::move(callback);
  }

  void OnFileChooserRequested(FileChooserRequestedCallback callback) {
    file_chooser_requested_callback_ = std::move(callback);
  }

  void OnDevtoolsProtocolEvent(DevtoolsProtocolEventCallback callback) {
    devtools_protocol_event_callback_ = std::move(callback);
  }

  void OnContainsFullScreenElementChanged(
      ContainsFullScreenElementChangedCallback callback) {
    contains_fullscreen_element_changed_callback_ = std::move(callback);
  }

 private:
  HWND hwnd_;
  HWND flutter_view_hwnd_;
  bool owns_window_;
  bool is_valid_ = false;
  // The geometry last applied by SetSurfaceSize and the bounds derived from
  // it. Pointer coordinates are scaled by surface_geometry_.scale_factor.
  util::SurfaceGeometry surface_geometry_;
  RECT bounds_ = {};
  wil::com_ptr<ICoreWebView2CompositionController> composition_controller_;
  wil::com_ptr<ICoreWebView2Controller3> webview_controller_;
  wil::com_ptr<ICoreWebView2> webview_;
  wil::com_ptr<ICoreWebView2DevToolsProtocolEventReceiver>
      devtools_protocol_event_receiver_;
  wil::com_ptr<ICoreWebView2DevToolsProtocolEventReceiver>
      file_chooser_receiver_;
  bool file_chooser_interception_enabled_ = false;
  wil::com_ptr<ICoreWebView2Settings> settings_;
  wil::com_ptr<ICoreWebView2Settings2> settings2_;
  POINT last_cursor_pos_ = {0, 0};
  VirtualKeyState virtual_keys_;
  WebviewPopupWindowPolicy popup_window_policy_ =
      WebviewPopupWindowPolicy::Allow;

  winrt::com_ptr<ABI::Windows::UI::Composition::IVisual> surface_;
  winrt::com_ptr<ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget>
      window_target_;

  WebviewHost* host_;
  EventRegistrations event_registrations_{};
  BasicAuthCredential basic_auth_;

  UrlChangedCallback url_changed_callback_;
  LoadingStateChangedCallback loading_state_changed_callback_;
  DownloadEventCallback download_event_callback_;
  OnLoadErrorCallback on_load_error_callback_;
  HistoryChangedCallback history_changed_callback_;
  DocumentTitleChangedCallback document_title_changed_callback_;
  SurfaceSizeChangedCallback surface_size_changed_callback_;
  CursorChangedCallback cursor_changed_callback_;
  FocusChangedCallback focus_changed_callback_;
  WebMessageReceivedCallback web_message_received_callback_;
  PermissionRequestedCallback permission_requested_callback_;
  FileChooserRequestedCallback file_chooser_requested_callback_;
  DevtoolsProtocolEventCallback devtools_protocol_event_callback_;
  ContainsFullScreenElementChangedCallback
      contains_fullscreen_element_changed_callback_;

  Webview(
      wil::com_ptr<ICoreWebView2CompositionController> composition_controller,
      WebviewHost* host, HWND hwnd, HWND flutter_view_hwnd, bool owns_window,
      bool offscreen_only);

  bool CreateSurface(
      winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor,
      HWND hwnd, bool offscreen_only);
  void RegisterEventHandlers();
  void EnableSecurityUpdates();
  // Returns false when CDP refuses the setup, which must leave WebView2's own
  // dialog in place instead of intercepting clicks the app cannot answer.
  bool EnableFileChooserInterception();
  // Reads the element behind an intercepted chooser and hands it to the
  // callback; the description is optional (see FileChooserRequestedCallback).
  void DescribeFileChooserNode(int mode, const std::string& backend_node_id);
  void SendScroll(double offset, bool horizontal);
};
