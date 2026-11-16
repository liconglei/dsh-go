import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/http/http_host_link.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/discard_guard.dart';
import '../common/smooth_size.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'link_progress.dart';

/// Add or edit a host reached over HTTP(S) with an account and password.
///
/// Kept apart from [SshHostFormPage] on purpose: nothing here is about SSH, so
/// sharing that form would mean hiding most of its fields and explaining the
/// rest. The saved config is still an [SshHostConfig] with
/// [SshDshMode.httpDirect], which is what keeps host switching, persistence and
/// the connection state machine untouched.
class HttpHostFormPage extends ConsumerStatefulWidget {
  const HttpHostFormPage({super.key, this.existing});

  /// Null to add a new host.
  final SshHostConfig? existing;

  @override
  ConsumerState<HttpHostFormPage> createState() => _HttpHostFormPageState();
}

enum _F { url, user, password }

class _HttpHostFormPageState extends ConsumerState<HttpHostFormPage> {
  late final String _id = widget.existing?.id ?? SshHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.host ?? '');
  late final _user = TextEditingController(text: widget.existing?.user ?? '');
  final _password = TextEditingController();

  bool _obscure = true;
  bool _saving = false;
  String? _formError;
  Map<_F, String> _errors = const {};
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  HttpHostLink? _test;
  StreamSubscription<HostLinkStatus>? _testSub;
  HostLinkStatus? _testStatus;

  bool get _editing => widget.existing != null;

  late String _clean;
  late final Listenable _edits = Listenable.merge([_name, _url, _user, _password]);

  String _signature() => jsonEncode({
    'name': _name.text,
    'url': _url.text,
    'user': _user.text,
    'password': _password.text,
  });

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    if (_editing) unawaited(_loadPassword());
  }

  /// The stored password is the only secret here; reading it fills the field so
  /// saving again keeps it without the person retyping.
  Future<void> _loadPassword() async {
    final initial = _password.text;
    final SshSecrets secrets;
    try {
      secrets = await ref.read(hostsProvider.notifier).loadSecrets(_id);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    // A password typed while secure storage was being read wins.
    if (_password.text != initial) return;
    setState(() {
      _password.text = secrets.password ?? '';
      _clean = _signature();
    });
  }

  @override
  void dispose() {
    unawaited(_testSub?.cancel());
    unawaited(_test?.close());
    for (final c in [_name, _url, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The config as typed; null (with [_errors] set) when incomplete.
  SshHostConfig? _draft() {
    final url = _url.text.trim();
    final user = _user.text.trim();
    final errors = <_F, String>{
      if (url.isEmpty) _F.url: context.l10n.remoteSshAddressRequired,
      if (url.isNotEmpty && !isValidBasicUrl(url)) _F.url: context.l10n.remoteHttpDirectUrlInvalid,
      if (user.isEmpty) _F.user: context.l10n.remoteSshUsernameRequired,
      if (_password.text.isEmpty) _F.password: context.l10n.remoteSshPasswordRequired,
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) {
      final first = _F.values.firstWhere(errors.containsKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[first]!.currentContext;
        if (target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.3,
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.glide,
          ),
        );
      });
      return null;
    }
    final parsed = Uri.tryParse(url);
    return SshHostConfig(
      id: _id,
      name: _name.text.trim().isEmpty ? (parsed?.host.isNotEmpty ?? false ? parsed!.host : url) : _name.text.trim(),
      host: url,
      // Unused for this mode; kept at the SSH defaults so a config never carries
      // a half-set address.
      port: widget.existing?.port ?? 22,
      user: user,
      auth: SshAuthMethod.password,
      dshMode: SshDshMode.httpDirect,
      remotePort: widget.existing?.remotePort ?? 3080,
      compression: widget.existing?.compression ?? true,
      launchCommand: widget.existing?.launchCommand ?? defaultDshLaunchCommand,
      workingDirectory: widget.existing?.workingDirectory,
      hostKeyType: null,
      hostKeyFingerprint: null,
    );
  }

  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  SshSecrets get _secrets => SshSecrets(
    password: _password.text,
    privateKey: null,
    passphrase: null,
    attachToken: null,
  );

  Future<void> _runTest() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    await _testSub?.cancel();
    await _test?.close();
    // The typed password, not the stored one: 测试连接 must try what is on screen.
    final password = _password.text;
    final link = HttpHostLink(config: config, loadPassword: () async => password);
    _test = link;
    setState(() => _testStatus = const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    _testSub = link.statuses.listen((s) {
      if (mounted && s.phase != HostLinkPhase.idle) setState(() => _testStatus = s);
    });
    try {
      await link.open();
    } catch (_) {
      // Shown in the progress card.
    } finally {
      await _testSub?.cancel();
      _testSub = null;
      if (identical(_test, link)) {
        _test = null;
        if (mounted) setState(() {});
      }
      await link.close();
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(hostsProvider.notifier).saveSsh(config, secrets: _secrets);
      if (!mounted) return;
      if (!saved) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        return;
      }
      Navigator.of(context).pop(config);
    } catch (_) {
      if (mounted) setState(() => _formError = context.l10n.commonSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final name = widget.existing!.name;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteDeleteHostTitle(name)),
        content: Text(context.l10n.remoteDeleteHostBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(hostsProvider.notifier).removeSsh(_id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final testing = _test != null;
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteEditHost : l10n.remoteAddHttpHost,
      subtitle: _editing ? null : Text(l10n.remoteHttpHostIntro),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.url],
                      error: _errors[_F.url],
                      label: l10n.remoteHttpUrl,
                      helper: l10n.remoteHttpDirectHelp,
                      child: TextField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.url),
                        decoration: InputDecoration(
                          hintText: 'https://dsh.example.com',
                          error: _errors[_F.url] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.remoteAuthentication,
              footer: Text(l10n.remoteHttpCredentialHelp),
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      key: _fieldKeys[_F.user],
                      error: _errors[_F.user],
                      label: l10n.remoteUsername,
                      child: TextField(
                        controller: _user,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.user),
                        decoration: InputDecoration(
                          hintText: 'me',
                          error: _errors[_F.user] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.password],
                      error: _errors[_F.password],
                      label: l10n.remotePassword,
                      child: TextField(
                        controller: _password,
                        obscureText: _obscure,
                        obscuringCharacter: '•',
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                        onChanged: (_) => _edited(_F.password),
                        decoration: InputDecoration(
                          error: _errors[_F.password] == null ? null : const SizedBox.shrink(),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? l10n.remoteShow : l10n.commonHide,
                            icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _Reveal(
              child: _testStatus == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: LinkProgressCard(status: _testStatus!, onRetry: testing ? null : _runTest),
                    ),
            ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            const SizedBox(height: 96),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: _FormBar(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(l10n.commonSave),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Solid under the keys, faded above them, so the page never scrolls through
/// the buttons.
class _FormBar extends StatelessWidget {
  const _FormBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).scaffoldBackgroundColor;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0), base],
            ),
          ),
          child: const SizedBox(height: 24),
        ),
        ColoredBox(
          color: base,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
            child: Row(children: children),
          ),
        ),
      ],
    );
  }
}

/// [AnimatedSize] unless animations are off (a zero-duration AnimatedSize
/// re-dirties itself during layout).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}
