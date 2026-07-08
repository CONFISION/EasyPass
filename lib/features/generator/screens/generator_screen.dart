import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../providers/generator_provider.dart';

class GeneratorScreen extends ConsumerWidget {
  const GeneratorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generatorProvider);
    final notifier = ref.read(generatorProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Password Generator'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          // Generated Password Display
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                SelectableText(
                  state.generatedPassword.isEmpty
                      ? 'Select options below'
                      : state.generatedPassword,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${state.generatedPassword.length} characters',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Action Buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: state.generatedPassword.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(
                            ClipboardData(text: state.generatedPassword),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Password copied!'),
                            ),
                          );
                        },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => notifier.generate(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Regenerate'),
                ),
              ),
            ],
          ),
          if (state.generatedPassword.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: () => context.pop(state.generatedPassword),
                icon: const Icon(Icons.check_circle),
                label: const Text('Use This Password'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
              ),
            ),
          ],
              const SizedBox(height: 24),

              // Length Slider
              Text(
                'Length: ${state.length}',
                style: theme.textTheme.titleMedium,
              ),
              Slider(
                value: state.length.toDouble(),
                min: 4,
                max: 64,
                divisions: 60,
                label: '${state.length}',
                onChanged: (value) => notifier.setLength(value.toInt()),
              ),
              const SizedBox(height: 16),

              // Options
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('Uppercase (A-Z)'),
                      subtitle: const Text('Include uppercase letters'),
                      value: state.useUppercase,
                      onChanged: (_) => notifier.toggleUppercase(),
                    ),
                    SwitchListTile(
                      title: const Text('Lowercase (a-z)'),
                      subtitle: const Text('Include lowercase letters'),
                      value: state.useLowercase,
                      onChanged: (_) => notifier.toggleLowercase(),
                    ),
                    SwitchListTile(
                      title: const Text('Numbers (0-9)'),
                      subtitle: const Text('Include numbers'),
                      value: state.useNumbers,
                      onChanged: (_) => notifier.toggleNumbers(),
                    ),
                    SwitchListTile(
                      title: const Text('Symbols (!@#\$...)'),
                      subtitle: const Text('Include special characters'),
                      value: state.useSymbols,
                      onChanged: (_) => notifier.toggleSymbols(),
                    ),
                  ],
                ),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}