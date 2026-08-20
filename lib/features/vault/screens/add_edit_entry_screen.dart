import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';
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
      final generatedPassword =
          ref.read(generatorProvider).generatedPassword;
      if (generatedPassword.isNotEmpty) {
        _passwordController.text = generatedPassword;
      }
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
    if (!_formKey.currentState!.validate()) return;
    if (_passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password is required'),
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
            content: Text(widget.isEditing ? 'Entry updated' : 'Entry saved')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit Entry' : 'Add Entry'),
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
                    decoration: const InputDecoration(
                      labelText: 'Name *',
                      hintText: 'e.g., Google, GitHub',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.label),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Name is required';
                      }
                      return null;
                    },
                    autofocus: !widget.isEditing,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'URL',
                      hintText: 'e.g., https://example.com',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username / Email',
                      hintText: 'e.g., user@example.com',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password *',
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
                            tooltip: 'Generate password',
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
                    decoration: const InputDecoration(
                      labelText: 'TOTP Secret (2FA)',
                      hintText: 'Base32 secret for authenticator',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.pin),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildFolderDropdown(context, ref),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'Additional notes...',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.note),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('Favorite'),
                    subtitle: const Text('Mark this entry as favorite'),
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
                          ? 'Save Changes'
                          : 'Add Entry'),
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
    final foldersAsync = ref.watch(foldersProvider);
    return foldersAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (folders) => DropdownButtonFormField<String?>(
        initialValue: _selectedFolderId,
        decoration: const InputDecoration(
          labelText: 'Folder',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.folder),
        ),
        isExpanded: true,
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('No Folder')),
          ...folders.map(
            (f) => DropdownMenuItem<String?>(value: f.id, child: Text(f.name)),
          ),
        ],
        onChanged: (value) => setState(() => _selectedFolderId = value),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text('Are you sure? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
