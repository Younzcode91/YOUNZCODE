part of '../main.dart';

// Model-provider presets shown in MODEL SETTINGS (OpenAI-compatible plus the
// native Anthropic/Gemini entries).

class _ProviderPreset {
  const _ProviderPreset({
    required this.label,
    required this.baseUrl,
    required this.models,
    required this.keyHint,
  });

  final String label;
  final String baseUrl; // empty => custom, leave existing fields untouched
  final List<String> models;
  final String keyHint;
}

const _customProviderLabel = 'Custom / OpenAI-compatible';

// Most providers here speak the OpenAI Chat Completions protocol, so only the
// Base URL, example models, and where-to-get-the-key hint differ. The two
// "(native)" presets point at api.anthropic.com and Google's generateContent
// endpoint; AgentService.detectProviderProtocol() routes those through the
// native adapters (x-api-key / x-goog-api-key), so no OpenAI-compat proxy is
// needed. Claude and Gemini can also be reached via OpenRouter or Google's
// OpenAI-compatible endpoint below.
const _providerPresets = <_ProviderPreset>[
  _ProviderPreset(
    label: _customProviderLabel,
    baseUrl: '',
    models: [],
    keyHint: 'Base URL & model bebas selama endpoint OpenAI-compatible.',
  ),
  _ProviderPreset(
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-4.1', 'gpt-4o', 'o4-mini'],
    keyHint: 'API key dari platform.openai.com/api-keys',
  ),
  _ProviderPreset(
    label: 'Anthropic Claude (native)',
    baseUrl: 'https://api.anthropic.com',
    models: ['claude-opus-4-8', 'claude-sonnet-5', 'claude-haiku-4-5'],
    keyHint: 'API key dari console.anthropic.com — protokol Messages native.',
  ),
  _ProviderPreset(
    label: 'Google Gemini (native)',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: ['gemini-2.5-pro', 'gemini-2.5-flash'],
    keyHint:
        'API key dari aistudio.google.com/apikey — generateContent native.',
  ),
  _ProviderPreset(
    label: 'OpenRouter (Claude, Gemini, dll)',
    baseUrl: 'https://openrouter.ai/api/v1',
    models: [
      'anthropic/claude-sonnet-4',
      'google/gemini-2.5-pro',
      'openai/gpt-4.1',
    ],
    keyHint: 'Satu key untuk banyak model — openrouter.ai/keys',
  ),
  _ProviderPreset(
    label: 'Google Gemini (OpenAI-compatible)',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    models: ['gemini-2.5-pro', 'gemini-2.5-flash'],
    keyHint: 'API key dari aistudio.google.com/apikey',
  ),
  _ProviderPreset(
    label: 'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    models: ['deepseek-ai/deepseek-r1', 'meta/llama-3.3-70b-instruct'],
    keyHint: 'API key dari build.nvidia.com',
  ),
  _ProviderPreset(
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    models: ['llama-3.3-70b-versatile', 'moonshotai/kimi-k2-instruct'],
    keyHint: 'API key dari console.groq.com/keys',
  ),
  _ProviderPreset(
    label: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    models: ['deepseek-chat', 'deepseek-reasoner'],
    keyHint: 'API key dari platform.deepseek.com',
  ),
  _ProviderPreset(
    label: '9router (lokal)',
    baseUrl: 'http://127.0.0.1:20128/v1',
    models: [],
    keyHint:
        'Jalankan 9router lokal, sambungkan provider di dashboard-nya; '
        'model & API key mengikuti dashboard tersebut.',
  ),
  _ProviderPreset(
    label: 'Ollama (lokal)',
    baseUrl: 'http://localhost:11434/v1',
    models: ['qwen2.5-coder', 'llama3.1'],
    keyHint: 'Server lokal Ollama; API key boleh diisi apa saja.',
  ),
];

_ProviderPreset _presetForBaseUrl(String url) {
  final normalized = url.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();
  for (final preset in _providerPresets) {
    if (preset.baseUrl.isNotEmpty &&
        preset.baseUrl.toLowerCase().replaceAll(RegExp(r'/+$'), '') ==
            normalized) {
      return preset;
    }
  }
  return _providerPresets.first;
}
