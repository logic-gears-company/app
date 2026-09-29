import 'package:Kelivo/core/services/axis_auth_service.dart';
import 'package:Kelivo/core/services/axis_cloud_service.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/section_card.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/shared/widgets/ios_settings_rows.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../shared/responsive/screen_type_helper.dart';

/// Browses the user's AXIS Cloud (WebDAV) files and shows the account it is
/// bound to. Reached from Settings.
class AxisCloudPage extends StatelessWidget {
  const AxisCloudPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (ResponsiveHelper.isDesktop(context)) {
      return const _AxisCloudDesktopLayout();
    }
    return const _AxisCloudMobileLayout();
  }
}

class _AxisCloudMobileLayout extends StatelessWidget {
  const _AxisCloudMobileLayout();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.axisCloudTitle),
      ),
      body: const _AxisCloudBody(),
    );
  }
}

/// On desktop a page-level bottom sheet is not allowed, so the content is laid
/// out in a centred column instead of a sheet.
class _AxisCloudDesktopLayout extends StatelessWidget {
  const _AxisCloudDesktopLayout();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.axisCloudTitle)),
      body: const _AxisCloudBody(maxWidth: 720),
    );
  }
}

class _AxisCloudBody extends StatefulWidget {
  const _AxisCloudBody({this.maxWidth});

  final double? maxWidth;

  @override
  State<_AxisCloudBody> createState() => _AxisCloudBodyState();
}

class _AxisCloudBodyState extends State<_AxisCloudBody> {
  /// Root-relative collection currently open, e.g. "" or "/notas".
  String _path = '';
  final _breadcrumbs = <String>[];

  List<AxisCloudEntry>? _entries;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await context.read<AxisCloudService>().list(_path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _open(AxisCloudEntry entry) {
    if (!entry.isDirectory) return;
    _breadcrumbs.add(_path);
    setState(() => _path = entry.path);
    _load();
  }

  void _up() {
    if (_breadcrumbs.isEmpty) return;
    setState(() {
      _path = _breadcrumbs.removeLast();
    });
    _load();
  }

  Future<void> _delete(AxisCloudEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.axisCloudDeleteConfirmTitle),
        content: Text(l10n.axisCloudDeleteConfirmBody(entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.axisCloudDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final response = await context.read<AxisCloudService>().delete(
        entry.path,
      );
      if (!mounted) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _showError('HTTP ${response.statusCode}');
        return;
      }
      _load();
    } catch (error) {
      if (mounted) _showError('$error');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AccountCard(onSignOut: _signOut),
        const SizedBox(height: 16),
        Row(
          children: [
            if (_breadcrumbs.isNotEmpty)
              IconButton(
                icon: const Icon(Lucide.ArrowUp, size: 20),
                tooltip: l10n.axisCloudUp,
                onPressed: _up,
              ),
            Expanded(
              child: Text(
                l10n.axisCloudFiles,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Lucide.RefreshCw, size: 18),
              tooltip: l10n.axisCloudRetry,
              onPressed: _load,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildContent(l10n)),
      ],
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: widget.maxWidth == null
            ? content
            : Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: widget.maxWidth!),
                  child: content,
                ),
              ),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    if (_loading) {
      return Center(child: Text(l10n.axisCloudLoading));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _load,
              child: Text(l10n.axisCloudRetry),
            ),
          ],
        ),
      );
    }
    final entries = _entries ?? const <AxisCloudEntry>[];
    if (entries.isEmpty) {
      return Center(child: Text(l10n.axisCloudEmpty));
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          leading: Icon(
            entry.isDirectory ? Lucide.Folder : Lucide.File,
            size: 20,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: entry.modified == null
              ? null
              : Text(
                  l10n.axisCloudUpdated(_relative(entry.modified!)),
                  maxLines: 1,
                ),
          trailing: entry.isDirectory
              ? null
              : IconButton(
                  icon: const Icon(Lucide.Trash, size: 18),
                  tooltip: l10n.axisCloudDelete,
                  onPressed: () => _delete(entry),
                ),
          onTap: () => _open(entry),
        );
      },
    );
  }

  static String _relative(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min';
    if (delta.inHours < 24) return '${delta.inHours} h';
    if (delta.inDays < 7) return '${delta.inDays} d';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}';
  }

  Future<void> _signOut() async {
    await context.read<AxisAuthService>().logout();
    if (!mounted) return;
    setState(() {
      _entries = null;
      _path = '';
      _breadcrumbs.clear();
    });
  }
}

class _AccountCard extends StatefulWidget {
  const _AccountCard({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  /// `hasSession` reads secure storage, so the answer is not available while
  /// building. Start pessimistic and flip once it resolves.
  bool? _signedIn;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final signedIn = await context.read<AxisAuthService>().hasSession();
    if (!mounted) return;
    setState(() => _signedIn = signedIn);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final signedIn = _signedIn == true;
    return SectionCard(
      children: [
        IosNavRow(
          icon: Lucide.CloudSun,
          label: l10n.axisCloudAccount,
          subtitle: signedIn
              ? AxisAuthService.baseUrl
              : l10n.axisCloudSignInRequired,
        ),
        if (signedIn)
          IosNavRow(
            icon: Lucide.Power,
            label: l10n.axisCloudSignOut,
            onTap: widget.onSignOut,
          ),
      ],
    );
  }
}
