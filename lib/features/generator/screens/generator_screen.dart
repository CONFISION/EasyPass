import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../providers/generator_provider.dart';

class GeneratorScreen extends ConsumerWidget {
  const GeneratorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generatorProvider);
    final notifier = ref.read(generatorProvider.notifier);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.passwordGenerator),
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
                      ? l10n.selectOptionsBelow
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
                      l10n.charactersCount(state.generatedPassword.length),
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
                            SnackBar(
                              content: Text(l10n.passwordCopiedExcl),
                            ),
                          );
                        },
                  icon: const Icon(Icons.copy),
                  label: Text(l10n.copy),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => notifier.generate(),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.regenerate),
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
                label: Text(l10n.useThisPassword),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
              ),
            ),
          ],
              const SizedBox(height: 24),

              // Length Slider
              Text(
                l10n.lengthLabel(state.length),
                style: theme.textTheme.titleMedium,
              ),
              Slider(
                value: state.length.toDouble(),
                // 与 GeneratorNotifier.setLength 的 clamp(4, 128) 对齐：
                // 上限必须是 128，否则 65..128 这段永远滑不到。
                min: 4,
                max: 128,
                divisions: 124,
                label: '${state.length}',
                onChanged: (value) => notifier.setLength(value.toInt()),
              ),
              const SizedBox(height: 16),

              // Options
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(l10n.uppercase),
                      subtitle: Text(l10n.uppercaseSubtitle),
                      value: state.useUppercase,
                      onChanged: (_) => notifier.toggleUppercase(),
                    ),
                    SwitchListTile(
                      title: Text(l10n.lowercase),
                      subtitle: Text(l10n.lowercaseSubtitle),
                      value: state.useLowercase,
                      onChanged: (_) => notifier.toggleLowercase(),
                    ),
                    SwitchListTile(
                      title: Text(l10n.numbers),
                      subtitle: Text(l10n.numbersSubtitle),
                      value: state.useNumbers,
                      onChanged: (_) => notifier.toggleNumbers(),
                    ),
                    SwitchListTile(
                      title: Text(l10n.symbols),
                      subtitle: Text(l10n.symbolsSubtitle),
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
