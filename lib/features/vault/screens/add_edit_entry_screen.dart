import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/providers/auth_provider.dart';
import '../../generator/providers/generator_provider.dart';
import '../providers/vault_provider.dart';

class AddEditEntryScreen extends ConsumerStatefulWidget {
  final String? entryId;

  const AddEditEntryScreen({super.key, this.entryId});

  bool get isEditing => entryId != null;

  @override
  ConsumerState<AddEditEntryScreen> createState() => _AddEditEntryScreenState();
}

class _AddEditEntryScreenState extends ConsumerState<AddEditEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _notesController = TextEditingController();
  final _totpSecretController = TextEditingController();

  String? _selectedFolderId;
  bool _obscurePassword = true;
  bool _isSaving = false;
  bool _isFavorite = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) {
      _loadEntry();
    } else {
      // The generator provider is a session-wide singleton that only
      // generates a password once at construction. Regenerate after the first
      // frame so every new entry gets a fresh suggested password instead of
      // the same one for the whole session (it used to stay fixed until
      // restart). Deferred because mutating a provider during initState
      // (widget tree build) is not allowed by Riverpod.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(generatorProvider.notifier).generate();
        final generatedPassword =
            ref.read(generatorProvider).generatedPassword;
        if (generatedPassword.isNotEmpty) {
          _passwordController.text = generatedPassword;
        }
      });
    }
  }

  Future<void> _loadEntry() async {
    final entry = await ref.read(selectedEntryProvider(widget.entryId!).future);
    if (entry == null || !mounted) return;

    final key = ref.read(encryptionKeyProvider);
    final crypto = CryptoService();

    _nameController.text = entry.name;
    _urlController.text = entry.url;
    _usernameController.text = entry.username;

    try {
      _passwordController.text =
          key != null ? crypto.decryptData(entry.passwordEncrypted, key) : '';
    } catch (_) {
      _passwordController.text = '';
    }

    // Decrypt notes / TOTP secret too — storing ciphertext in the edit fields
    // would re-encrypt it on save and permanently corrupt the entry.
    try {
      _notesController.text =
          (entry.notesEncrypted ?? '').isEmpty
              ? ''
              : crypto.decryptData(entry.notesEncrypted!, key!);
    } catch (_) {
      _notesController.text = '';
    }

    try {
      _totpSecretController.text =
          (entry.totpSecretEncrypted ?? '').isEmpty
              ? ''
              : crypto.decryptData(entry.totpSecretEncrypted!, key!);
    } catch (_) {
      _totpSecretController.text = '';
    }

    _isFavorite = entry.isFavorite;
    _selectedFolderId = entry.folderId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _notesController.dispose();
    _totpSecretController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate()) return;
    if (_passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.passwordRequired),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final entry = PasswordEntriesCompanion(
        id: widget.isEditing
            ? Value(widget.entryId!)
            : Value(const Uuid().v4()),
        name: Value(_nameController.text.trim()),
        url: Value(_urlController.text.trim()),
        username: Value(_usernameController.text.trim()),
        passwordEncrypted: Value(_encryptField(_passwordController.text)),
        notesEncrypted: Value(_encryptField(_notesController.text)),
        totpSecretEncrypted: Value(_encryptField(_totpSecretController.text)),
        isFavorite: Value(_isFavorite),
        folderId: _selectedFolderId != null
            ? Value(_selectedFolderId!)
            : const Value.absent(),
        createdAt: widget.isEditing ? const Value.absent() : Value(now),
        updatedAt: Value(now),
      );

      final repo = ref.read(vaultRepositoryProvider);
      if (widget.isEditing) {
        await repo.updateEntry(widget.entryId!, entry);
      } else {
        await repo.saveEntry(entry);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                widget.isEditing ? l10n.entryUpdated : l10n.entrySaved),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.failedToSaveEntry(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Encrypt a plaintext field, or keep it unchanged if encryption fails
  /// (e.g. session key missing) rather than throwing away user input.
  String _encryptField(String plaintext) {
    if (plaintext.isEmpty) return '';
    final key = ref.read(encryptionKeyProvider);
    if (key == null) return plaintext;
    try {
      return CryptoService().encryptData(plaintext, key);
    } catch (_) {
      return plaintext;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? l10n.editEntryTitle : l10n.addEntryTitle),
        actions: [
          if (widget.isEditing)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _confirmDelete(context),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: l10n.nameLabel,
                      hintText: l10n.nameHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.label),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.nameRequired;
                      }
                      return null;
                    },
                    autofocus: !widget.isEditing,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: l10n.urlLabel,
                      hintText: l10n.urlHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.link),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      labelText: l10n.usernameLabel,
                      hintText: l10n.usernameHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.person),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: l10n.passwordLabel,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(_obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                          IconButton(
                            icon: const Icon(Icons.auto_fix_high),
                            tooltip: l10n.generatePasswordTooltip,
                            onPressed: () async {
                              final result =
                                  await context.push<String>('/generator');
                              if (result != null && mounted) {
                                _passwordController.text = result;
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _totpSecretController,
                    decoration: InputDecoration(
                      labelText: l10n.totpSecretLabel,
                      hintText: l10n.totpSecretHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.pin),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildFolderDropdown(context, ref),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notesController,
                    decoration: InputDecoration(
                      labelText: l10n.notesLabel,
                      hintText: l10n.notesHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.note),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: Text(l10n.favorite),
                    subtitle: Text(l10n.favoriteSubtitle),
                    value: _isFavorite,
                    onChanged: (value) =>
                        setState(() => _isFavorite = value),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Icon(widget.isEditing
                              ? Icons.save
                              : Icons.add),
                      label: Text(widget.isEditing
                          ? l10n.saveChanges
                          : l10n.addEntryTitle),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFolderDropdown(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final foldersAsync = ref.watch(foldersProvider);
    return foldersAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (folders) => DropdownButtonFormField<String?>(
        initialValue: _selectedFolderId,
        decoration: InputDecoration(
          labelText: l10n.folderTitle,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.folder),
        ),
        isExpanded: true,
        items: [
          DropdownMenuItem<String?>(value: null, child: Text(l10n.noFolder)),
          ...folders.map(
            (f) => DropdownMenuItem<String?>(value: f.id, child: Text(f.name)),
          ),
        ],
        onChanged: (value) => setState(() => _selectedFolderId = value),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteEntryTitle),
        content: Text(l10n.deleteEntryMessage),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              await ref
                  .read(vaultRepositoryProvider)
                  .deleteEntry(widget.entryId!);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) context.pop();
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }
}
