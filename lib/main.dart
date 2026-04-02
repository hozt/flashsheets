import 'dart:convert';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const FlashSheetsApp());
}

class FlashSheetsApp extends StatelessWidget {
  const FlashSheetsApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFFEAF1FF);
    const navy = Color(0xFF0E2A5A);
    const cyan = Color(0xFF1D9BF0);
    const coral = Color(0xFFF25F5C);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flashcard Sheets',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: navy,
          primary: navy,
          secondary: cyan,
          error: coral,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        scaffoldBackgroundColor: background,
      ),
      home: const FlashDeckPage(),
    );
  }
}

class FlashDeckPage extends StatefulWidget {
  const FlashDeckPage({super.key});

  @override
  State<FlashDeckPage> createState() => _FlashDeckPageState();
}

class _FlashDeckPageState extends State<FlashDeckPage> {
  static const _storedDecksKey = 'stored_decks_v1';
  static const _activeDeckIndexKey = 'active_deck_index_v1';
  static const _reverseCardsKey = 'reverse_cards_v1';
  static const _reviewMissedOnlyKey = 'review_missed_only_v1';
  static const _languageCodeKey = 'language_code_v1';
  static const _androidServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );

  final _linkController = TextEditingController();
  final _loader = SheetDeckLoader();
  final _googleSignIn = GoogleSignIn.instance;
  final _random = Random();

  List<InstalledDeck> _installedDecks = [];
  int? _activeDeckIndex;
  bool _reverseCards = false;
  bool _reviewMissedOnly = false;
  AppLanguage _language = AppLanguage.english;

  GoogleSignInAccount? _account;
  bool _loading = false;
  String? _error;

  int _index = 0;
  int _right = 0;
  int _wrong = 0;
  bool _showAnswer = false;

  AppStrings get _strings => AppStrings(_language);
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _hasAndroidServerClientId =>
      _androidServerClientId.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadPersistedState();
    _initializeGoogleSignIn();
  }

  Future<void> _loadPersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawDecks = prefs.getString(_storedDecksKey);
      final rawActiveIndex = prefs.getInt(_activeDeckIndexKey);
      final reverse = prefs.getBool(_reverseCardsKey) ?? false;
      final reviewMissedOnly = prefs.getBool(_reviewMissedOnlyKey) ?? false;
      final languageCode =
          prefs.getString(_languageCodeKey) ?? AppLanguage.english.code;

      final installed = <InstalledDeck>[];
      if (rawDecks != null && rawDecks.isNotEmpty) {
        final decoded = jsonDecode(rawDecks) as List<dynamic>;
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            installed.add(InstalledDeck.fromJson(item));
          } else if (item is Map) {
            installed.add(InstalledDeck.fromJson(item.cast<String, dynamic>()));
          }
        }
      }

      int? activeIndex;
      if (rawActiveIndex != null &&
          rawActiveIndex >= 0 &&
          rawActiveIndex < installed.length) {
        activeIndex = rawActiveIndex;
      } else if (installed.isNotEmpty) {
        activeIndex = 0;
      }

      if (!mounted) return;
      setState(() {
        _installedDecks = installed
            .map((deck) => deck.copyWith(cards: _shuffleCards(deck.cards)))
            .toList(growable: false);
        _activeDeckIndex = activeIndex;
        _reverseCards = reverse;
        _reviewMissedOnly = reviewMissedOnly;
        _language = appLanguageFromCode(languageCode);
      });
      _persistState();
    } catch (_) {
      // Keep app usable even if persisted data is invalid.
    }
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    final encodedDecks = jsonEncode(
      _installedDecks.map((deck) => deck.toJson()).toList(growable: false),
    );
    await prefs.setString(_storedDecksKey, encodedDecks);
    if (_activeDeckIndex != null) {
      await prefs.setInt(_activeDeckIndexKey, _activeDeckIndex!);
    } else {
      await prefs.remove(_activeDeckIndexKey);
    }
    await prefs.setBool(_reverseCardsKey, _reverseCards);
    await prefs.setBool(_reviewMissedOnlyKey, _reviewMissedOnly);
    await prefs.setString(_languageCodeKey, _language.code);
  }

  Future<void> _initializeGoogleSignIn() async {
    try {
      if (_isAndroid && _hasAndroidServerClientId) {
        await _googleSignIn.initialize(serverClientId: _androidServerClientId);
      } else {
        await _googleSignIn.initialize();
      }

      _googleSignIn.authenticationEvents.listen((
        GoogleSignInAuthenticationEvent event,
      ) {
        setState(() {
          _account = switch (event) {
            GoogleSignInAuthenticationEventSignIn() => event.user,
            GoogleSignInAuthenticationEventSignOut() => null,
          };
        });
      });

      if (!(_isAndroid && !_hasAndroidServerClientId)) {
        final restoreAttempt = _googleSignIn.attemptLightweightAuthentication();
        if (restoreAttempt != null) {
          final user = await restoreAttempt;
          if (mounted) {
            setState(() {
              _account = user;
            });
          }
        }
      }
    } catch (_) {
      // Keep public-share-link mode available even when Google SDK is unavailable.
    }
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _loadPublicSheet() async {
    final s = _strings;
    final input = _linkController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = s.pasteLinkFirst;
      });
      return;
    }
    await _loadDeck(
      mode: SheetLoadMode.publicShareLink,
      input: input,
      action: () => _loader.loadFromShareLink(input),
    );
  }

  Future<void> _loadPrivateSheet() async {
    final s = _strings;
    final input = _linkController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = s.pasteLinkFirst;
      });
      return;
    }

    await _loadAuthorizedSheet(input);
  }

  InstalledDeck? get _activeDeck {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) {
      return null;
    }
    return _installedDecks[index];
  }

  List<FlashCard> get _activeCards {
    final deck = _activeDeck;
    if (deck == null) return const [];
    if (!_reviewMissedOnly) return deck.cards;
    return deck.cards
        .where((card) => (deck.missedCounts[deck.cardKey(card)] ?? 0) > 0)
        .toList(growable: false);
  }

  int get _activeMissedCount {
    final deck = _activeDeck;
    if (deck == null) return 0;
    return deck.missedCounts.values.fold<int>(0, (sum, value) => sum + value);
  }

  List<FlashCard> _shuffleCards(List<FlashCard> cards) {
    final shuffled = [...cards];
    shuffled.shuffle(_random);
    return shuffled;
  }

  String _deckNameFromInput(String input) {
    final s = _strings;
    try {
      final source = SpreadsheetSource.parse(input);
      return '${s.sheet} ${source.spreadsheetId.substring(0, 8)}';
    } catch (_) {
      return s.sheet;
    }
  }

  Map<String, int> _retainCountsForCurrentCards(
    Map<String, int> existing,
    List<FlashCard> cards,
  ) {
    final allowedKeys = cards
        .map((card) => InstalledDeck.cardKeyFor(card))
        .toSet();
    final retained = <String, int>{};
    for (final entry in existing.entries) {
      if (allowedKeys.contains(entry.key) && entry.value > 0) {
        retained[entry.key] = entry.value;
      }
    }
    return retained;
  }

  Future<void> _loadDeck({
    required SheetLoadMode mode,
    required String input,
    required Future<List<FlashCard>> Function() action,
  }) async {
    final s = _strings;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final loaded = await action();
      if (loaded.isEmpty) {
        setState(() {
          _error = s.noCardsFound;
          _loading = false;
        });
        return;
      }

      setState(() {
        final updated = [..._installedDecks];
        final existingIndex = updated.indexWhere(
          (deck) => deck.mode == mode && deck.sourceInput == input,
        );
        final deck = InstalledDeck(
          name: _deckNameFromInput(input),
          mode: mode,
          sourceInput: input,
          cards: _shuffleCards(loaded),
          missedCounts: existingIndex == -1
              ? const {}
              : _retainCountsForCurrentCards(
                  updated[existingIndex].missedCounts,
                  loaded,
                ),
          correctCounts: existingIndex == -1
              ? const {}
              : _retainCountsForCurrentCards(
                  updated[existingIndex].correctCounts,
                  loaded,
                ),
        );
        if (existingIndex == -1) {
          updated.add(deck);
          _activeDeckIndex = updated.length - 1;
        } else {
          updated[existingIndex] = deck;
          _activeDeckIndex = existingIndex;
        }
        _installedDecks = updated;
        _index = 0;
        _right = 0;
        _wrong = 0;
        _showAnswer = false;
        _loading = false;
      });
      await _persistState();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool get _sessionDone =>
      _activeCards.isNotEmpty && _index >= _activeCards.length;

  Future<void> _loadAuthorizedSheet(String input) async {
    final s = _strings;
    try {
      if (_isAndroid && !_hasAndroidServerClientId) {
        setState(() {
          _error = s.androidServerClientIdMissing;
        });
        return;
      }
      final account = _account ?? await _googleSignIn.authenticate();
      final authHeaders = await account.authorizationClient
          .authorizationHeaders(const [
            'https://www.googleapis.com/auth/spreadsheets.readonly',
          ], promptIfNecessary: true);

      if (authHeaders == null) {
        setState(() {
          _error = s.oauthHeadersFailed;
        });
        return;
      }

      await _loadDeck(
        mode: SheetLoadMode.authorized,
        input: input,
        action: () => _loader.loadWithAuth(input, authHeaders),
      );
    } catch (e) {
      setState(() {
        _error = '${s.googleSignInFailed}: $e';
      });
    }
  }

  Future<void> _refreshSheet() async {
    final s = _strings;
    final deck = _activeDeck;
    if (deck == null) {
      setState(() {
        _error = s.loadSheetBeforeRefresh;
      });
      return;
    }

    if (deck.mode == SheetLoadMode.publicShareLink) {
      await _loadDeck(
        mode: deck.mode,
        input: deck.sourceInput,
        action: () => _loader.loadFromShareLink(deck.sourceInput),
      );
      return;
    }

    await _loadAuthorizedSheet(deck.sourceInput);
  }

  void _markCard(bool isCorrect) {
    if (_activeCards.isEmpty || _sessionDone) return;

    final card = _activeCards[_index];
    setState(() {
      if (isCorrect) {
        _right++;
        _incrementCorrectForActiveDeck(card);
        _decrementMissedForActiveDeck(card);
      } else {
        _wrong++;
        _incrementMissedForActiveDeck(card);
      }
      final cardsAfter = _activeCards;
      if (cardsAfter.isEmpty) {
        _index = 0;
      } else {
        final cardStillInStudy = cardsAfter.any(
          (item) =>
              InstalledDeck.cardKeyFor(item) == InstalledDeck.cardKeyFor(card),
        );
        if (isCorrect && !cardStillInStudy && _reviewMissedOnly) {
          if (_index >= cardsAfter.length) {
            _index = cardsAfter.length - 1;
          }
        } else if (_index + 1 < cardsAfter.length) {
          _index++;
        } else {
          _index = cardsAfter.length;
        }
      }
      _showAnswer = false;
    });
    _persistState();
  }

  void _incrementMissedForActiveDeck(FlashCard card) {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) return;
    final current = _installedDecks[index];
    final key = current.cardKey(card);
    final nextCounts = <String, int>{...current.missedCounts};
    nextCounts[key] = (nextCounts[key] ?? 0) + 1;
    final updated = [..._installedDecks];
    updated[index] = current.copyWith(missedCounts: nextCounts);
    _installedDecks = updated;
  }

  void _incrementCorrectForActiveDeck(FlashCard card) {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) return;
    final current = _installedDecks[index];
    final key = current.cardKey(card);
    final nextCounts = <String, int>{...current.correctCounts};
    nextCounts[key] = (nextCounts[key] ?? 0) + 1;
    final updated = [..._installedDecks];
    updated[index] = current.copyWith(correctCounts: nextCounts);
    _installedDecks = updated;
  }

  void _decrementMissedForActiveDeck(FlashCard card) {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) return;
    final current = _installedDecks[index];
    final key = current.cardKey(card);
    final nextCounts = <String, int>{...current.missedCounts};
    final existing = nextCounts[key] ?? 0;
    if (existing <= 1) {
      nextCounts.remove(key);
    } else {
      nextCounts[key] = existing - 1;
    }
    final updated = [..._installedDecks];
    updated[index] = current.copyWith(missedCounts: nextCounts);
    _installedDecks = updated;
  }

  void _clearMissedForActiveDeck() {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) return;
    final updated = [..._installedDecks];
    updated[index] = updated[index].copyWith(missedCounts: const {});
    setState(() {
      _installedDecks = updated;
      _index = 0;
      _showAnswer = false;
      _reviewMissedOnly = false;
    });
    _persistState();
  }

  void _restartSession() {
    _randomizeActiveDeck();
  }

  void _resetStats() {
    setState(() {
      _right = 0;
      _wrong = 0;
    });
  }

  void _switchDeck(int index) {
    final updated = [..._installedDecks];
    updated[index] = updated[index].copyWith(
      cards: _shuffleCards(updated[index].cards),
    );
    setState(() {
      _installedDecks = updated;
      _activeDeckIndex = index;
      _index = 0;
      _right = 0;
      _wrong = 0;
      _showAnswer = false;
      _error = null;
    });
    _persistState();
  }

  void _randomizeActiveDeck() {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) return;
    final updated = [..._installedDecks];
    updated[index] = updated[index].copyWith(
      cards: _shuffleCards(updated[index].cards),
    );
    setState(() {
      _installedDecks = updated;
      _index = 0;
      _right = 0;
      _wrong = 0;
      _showAnswer = false;
      _error = null;
    });
    _persistState();
  }

  void _deleteActiveDeck() {
    final index = _activeDeckIndex;
    if (index == null || index < 0 || index >= _installedDecks.length) return;
    final updated = [..._installedDecks]..removeAt(index);
    int? nextIndex;
    if (updated.isNotEmpty) {
      nextIndex = index.clamp(0, updated.length - 1);
    }
    setState(() {
      _installedDecks = updated;
      _activeDeckIndex = nextIndex;
      _index = 0;
      _right = 0;
      _wrong = 0;
      _showAnswer = false;
      _error = null;
    });
    _persistState();
  }

  Future<void> _openSourcePage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) {
          return StatefulBuilder(
            builder: (pageContext, pageSetState) {
              final s = _strings;
              return Scaffold(
                appBar: AppBar(title: Text(s.googleSheetSource)),
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        if (_installedDecks.isNotEmpty) ...[
                          Row(
                            children: [
                              Text(
                                s.installedSets,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: _activeDeckIndex == null
                                    ? null
                                    : () {
                                        _deleteActiveDeck();
                                        pageSetState(() {});
                                      },
                                icon: const Icon(Icons.delete_outline_rounded),
                                iconSize: 26,
                                tooltip: s.deleteSelectedSet,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 42,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _installedDecks.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, i) => ChoiceChip(
                                label: Text(_installedDecks[i].name),
                                selected: _activeDeckIndex == i,
                                onSelected: (_) {
                                  _switchDeck(i);
                                  Navigator.of(pageContext).pop();
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        _SourcePanel(
                          strings: s,
                          controller: _linkController,
                          loading: _loading,
                          signedInEmail: _account?.email,
                          onLoadPublic: () async {
                            await _loadPublicSheet();
                            pageSetState(() {});
                          },
                          onLoadPrivate: () async {
                            await _loadPrivateSheet();
                            pageSetState(() {});
                          },
                          canClose: false,
                          onClose: () {},
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        if (_installedDecks.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => Navigator.of(pageContext).pop(),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(s.startStudying),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openPreferencesPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) {
          return StatefulBuilder(
            builder: (pageContext, pageSetState) {
              final s = _strings;
              return Scaffold(
                appBar: AppBar(title: Text(s.options)),
                body: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F8FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFB7C8E8)),
                      ),
                      child: Column(
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              SizedBox(
                                width: 165,
                                child: OutlinedButton.icon(
                                  onPressed: _loading ? null : _refreshSheet,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 24,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                  ),
                                  label: Text(
                                    s.refresh,
                                    style: const TextStyle(
                                      height: 1.0,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 165,
                                child: OutlinedButton.icon(
                                  onPressed: _activeCards.isEmpty
                                      ? null
                                      : _randomizeActiveDeck,
                                  icon: const Icon(
                                    Icons.shuffle_rounded,
                                    size: 24,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                  ),
                                  label: Text(
                                    s.randomize,
                                    style: const TextStyle(
                                      height: 1.0,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 165,
                                child: OutlinedButton.icon(
                                  onPressed: _activeCards.isEmpty
                                      ? null
                                      : _resetStats,
                                  icon: const Icon(
                                    Icons.restart_alt_rounded,
                                    size: 24,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                  ),
                                  label: Text(
                                    s.resetStats,
                                    style: const TextStyle(
                                      height: 1.0,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(
                                Icons.report_problem_outlined,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${s.reviewMissedOnly} ($_activeMissedCount)',
                              ),
                              const Spacer(),
                              Switch(
                                value: _reviewMissedOnly,
                                onChanged: (value) {
                                  setState(() {
                                    _reviewMissedOnly = value;
                                    _index = 0;
                                    _showAnswer = false;
                                  });
                                  pageSetState(() {});
                                  _persistState();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<AppLanguage>(
                            initialValue: _language,
                            decoration: InputDecoration(
                              labelText: s.languageLabel,
                              prefixIcon: const Icon(Icons.language_rounded),
                              border: const OutlineInputBorder(),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: AppLanguage.english,
                                child: Text(s.english),
                              ),
                              DropdownMenuItem(
                                value: AppLanguage.spanish,
                                child: Text(s.spanish),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _language = value;
                              });
                              pageSetState(() {});
                              _persistState();
                            },
                          ),
                          Row(
                            children: [
                              const Icon(Icons.swap_horiz_rounded, size: 18),
                              const SizedBox(width: 8),
                              Text(s.reverseCards),
                              const Spacer(),
                              Switch(
                                value: _reverseCards,
                                onChanged: (value) {
                                  setState(() {
                                    _reverseCards = value;
                                    _showAnswer = false;
                                  });
                                  pageSetState(() {});
                                  _persistState();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed:
                                  _activeDeck == null || _activeMissedCount == 0
                                  ? null
                                  : () {
                                      _clearMissedForActiveDeck();
                                      pageSetState(() {});
                                    },
                              icon: const Icon(Icons.delete_sweep_rounded),
                              label: Text(s.clearMissedRecords),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildStudyMode(AppStrings s) {
    return Column(
      children: [
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_activeCards.isNotEmpty && (_right + _wrong) > 0)
          Row(
            children: [
              _StatChip(
                label: s.right,
                value: _right,
                color: const Color(0xFF2A9D8F),
              ),
              const SizedBox(width: 8),
              _StatChip(
                label: s.wrong,
                value: _wrong,
                color: const Color(0xFFE76F51),
              ),
              const Spacer(),
            ],
          ),
        const SizedBox(height: 16),
        Expanded(child: Center(child: _buildCardArea())),
        if (_activeCards.isNotEmpty) ...[
          const SizedBox(height: 12),
          _AnswerActions(
            strings: s,
            enabled: !_sessionDone,
            onReveal: () {
              setState(() {
                _showAnswer = !_showAnswer;
              });
            },
            showAnswer: _showAnswer,
            onWrong: () => _markCard(false),
            onRight: () => _markCard(true),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _strings;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(s.appTitle),
        actions: [
          IconButton(
            onPressed: _openSourcePage,
            icon: const Icon(Icons.folder_open_outlined),
            iconSize: 26,
            tooltip: s.googleSheetSource,
          ),
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => AboutPage(strings: s)),
              );
            },
            icon: const Icon(Icons.info_outline_rounded),
            iconSize: 26,
            tooltip: s.about,
          ),
          IconButton(
            onPressed: _openPreferencesPage,
            icon: const Icon(Icons.tune_outlined),
            iconSize: 26,
            tooltip: s.options,
          ),
          if (_account != null)
            IconButton(
              onPressed: _googleSignIn.signOut,
              icon: const Icon(Icons.logout_rounded),
              iconSize: 26,
              tooltip: s.signOut,
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _buildStudyMode(s),
        ),
      ),
    );
  }

  Widget _buildCardArea() {
    final s = _strings;
    if (_loading) {
      return const CircularProgressIndicator();
    }

    if (_activeDeck != null && _activeCards.isEmpty && _reviewMissedOnly) {
      return _InfoCard(
        icon: Icons.check_circle_outline_rounded,
        title: s.noMissedCards,
        body: s.noMissedCardsBody,
        action: FilledButton(
          onPressed: () {
            setState(() {
              _reviewMissedOnly = false;
            });
            _persistState();
          },
          child: Text(s.studyAllCards),
        ),
      );
    }

    if (_activeCards.isEmpty) {
      return _InfoCard(
        icon: Icons.table_chart_rounded,
        title: s.loadYourSheet,
        body: s.loadYourSheetBody,
      );
    }

    if (_sessionDone) {
      return _InfoCard(
        icon: Icons.emoji_events_rounded,
        title: s.sessionComplete,
        body: '${s.right}: $_right\n${s.wrong}: $_wrong',
        action: FilledButton.icon(
          onPressed: _restartSession,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(s.restartSession),
        ),
      );
    }

    final card = _activeCards[_index];
    final frontText = _reverseCards ? card.answer : card.question;
    final backText = _reverseCards ? card.question : card.answer;
    final displayText = _showAnswer ? backText : frontText;
    final label = _showAnswer
        ? (_reverseCards ? s.question : s.answer)
        : (_reverseCards ? s.answer : s.question);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      transitionBuilder: (child, animation) {
        final offsetAnimation =
            Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );

        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      child: _FlashCardView(
        key: ValueKey('$_index-$_showAnswer'),
        label: label,
        text: displayText,
      ),
    );
  }
}

class _SourcePanel extends StatelessWidget {
  const _SourcePanel({
    required this.strings,
    required this.controller,
    required this.loading,
    required this.signedInEmail,
    required this.onLoadPublic,
    required this.onLoadPrivate,
    required this.canClose,
    required this.onClose,
  });

  final AppStrings strings;
  final TextEditingController controller;
  final bool loading;
  final String? signedInEmail;
  final Future<void> Function() onLoadPublic;
  final Future<void> Function() onLoadPrivate;
  final bool canClose;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  strings.googleSheetSource,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (canClose)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                  iconSize: 26,
                  tooltip: strings.collapseSource,
                ),
            ],
          ),
          if (signedInEmail != null) ...[
            const SizedBox(height: 4),
            Text(
              '${strings.signedInAs} $signedInEmail',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            strings.sourceDirections,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 12.5,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            enabled: !loading,
            decoration: InputDecoration(
              hintText: strings.pasteLinkHint,
              prefixIcon: const Icon(Icons.link_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: loading ? null : onLoadPublic,
                  icon: const Icon(Icons.public_rounded, size: 24),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  label: Text(
                    strings.installSharedSet,
                    style: const TextStyle(
                      height: 1.0,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: loading ? null : onLoadPrivate,
                  icon: const Icon(Icons.lock_open_rounded, size: 24),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  label: Text(
                    strings.authorizeAndInstall,
                    style: const TextStyle(
                      height: 1.0,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AnswerActions extends StatelessWidget {
  const _AnswerActions({
    required this.strings,
    required this.enabled,
    required this.onReveal,
    required this.showAnswer,
    required this.onWrong,
    required this.onRight,
  });

  final AppStrings strings;
  final bool enabled;
  final VoidCallback onReveal;
  final bool showAnswer;
  final VoidCallback onWrong;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) {
    final revealButton = OutlinedButton.icon(
      onPressed: enabled ? onReveal : null,
      icon: Icon(
        showAnswer ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        size: 26,
      ),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          showAnswer ? strings.hide : strings.reveal,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );

    final canScore = enabled && showAnswer;

    final wrongButton = FilledButton(
      onPressed: canScore ? onWrong : null,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFE76F51),
        minimumSize: const Size.fromHeight(70),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          strings.missed,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );

    final rightButton = FilledButton(
      onPressed: canScore ? onRight : null,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF2A9D8F),
        minimumSize: const Size.fromHeight(70),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          strings.correct,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: double.infinity, child: revealButton),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: wrongButton),
            const SizedBox(width: 10),
            Expanded(child: rightButton),
          ],
        ),
      ],
    );
  }
}

class _FlashCardView extends StatelessWidget {
  const _FlashCardView({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.all(26),
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B2A41), Color(0xFF324A6D)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: const Color(0xFF1B2A41)),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade700,
              height: 1.4,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(strings.about)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.appTitle,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(strings.aboutDescription),
            const SizedBox(height: 16),
            Text(
              strings.website,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const SelectableText('https://hozt.com'),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () {
                showLicensePage(
                  context: context,
                  applicationName: strings.appTitle,
                  applicationVersion: '1.0.0',
                );
              },
              icon: const Icon(Icons.article_outlined),
              label: Text(strings.viewLicenses),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 6, color: color),
          const SizedBox(width: 6),
          Text(
            '$label $value',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

enum AppLanguage { english, spanish }

extension on AppLanguage {
  String get code => this == AppLanguage.english ? 'en' : 'es';
}

AppLanguage appLanguageFromCode(String code) {
  if (code.toLowerCase().startsWith('es')) return AppLanguage.spanish;
  return AppLanguage.english;
}

class AppStrings {
  const AppStrings(this.language);

  final AppLanguage language;

  bool get _isSpanish => language == AppLanguage.spanish;

  String get appTitle => 'Flashcard Sheets';
  String get languageLabel => _isSpanish ? 'Idioma' : 'Language';
  String get english => _isSpanish ? 'Ingles' : 'English';
  String get spanish => _isSpanish ? 'Espanol' : 'Spanish';
  String get about => _isSpanish ? 'Acerca de' : 'About';
  String get options => _isSpanish ? 'Opciones' : 'Options';
  String get signOut => _isSpanish ? 'Cerrar sesion' : 'Sign out';
  String get installedSets =>
      _isSpanish ? 'Conjuntos instalados' : 'Installed sets';
  String get addNewSet => _isSpanish ? 'Agregar conjunto' : 'Add new set';
  String get deleteSelectedSet =>
      _isSpanish ? 'Eliminar conjunto seleccionado' : 'Delete selected set';
  String get right => _isSpanish ? 'Bien' : 'Right';
  String get wrong => _isSpanish ? 'Mal' : 'Wrong';
  String get refresh => _isSpanish ? 'Actualizar' : 'Refresh';
  String get randomize => _isSpanish ? 'Aleatorio' : 'Randomize';
  String get resetStats =>
      _isSpanish ? 'Reiniciar estadisticas' : 'Reset stats';
  String get reviewMissedOnly =>
      _isSpanish ? 'Repasar solo falladas' : 'Review missed only';
  String get reverseCards => _isSpanish ? 'Invertir tarjetas' : 'Reverse cards';
  String get clearMissedRecords =>
      _isSpanish ? 'Limpiar falladas' : 'Clear missed records';
  String get noMissedCards =>
      _isSpanish ? 'No hay tarjetas falladas' : 'No missed cards';
  String get noMissedCardsBody => _isSpanish
      ? 'Ya estas al dia. Desactiva "Repasar solo falladas" para estudiar todo.'
      : 'You are caught up. Turn off "Review missed only" to study all.';
  String get studyAllCards => _isSpanish ? 'Estudiar todas' : 'Study all cards';
  String get loadYourSheet => _isSpanish ? 'Carga tu hoja' : 'Load Your Sheet';
  String get loadYourSheetBody => _isSpanish
      ? 'Usa un enlace de Google Sheets con dos columnas:\nA = pregunta, B = respuesta.\n\nPuedes instalar varios conjuntos y cambiar entre ellos.'
      : 'Use a Google Sheets share link with two columns:\nA = question, B = answer.\n\nYou can install multiple sets and switch between them.';
  String get sessionComplete =>
      _isSpanish ? 'Sesion completada' : 'Session complete';
  String get restartSession =>
      _isSpanish ? 'Reiniciar sesion' : 'Restart session';
  String get startStudying =>
      _isSpanish ? 'Comenzar a estudiar' : 'Start Studying';
  String get backToCards => _isSpanish ? 'Volver a tarjetas' : 'Back to cards';
  String get question => _isSpanish ? 'Pregunta' : 'Question';
  String get answer => _isSpanish ? 'Respuesta' : 'Answer';
  String get googleSheetSource =>
      _isSpanish ? 'Fuente de Google Sheet' : 'Google Sheet Source';
  String get signedInAs => _isSpanish ? 'Sesion iniciada como' : 'Signed in as';
  String get pasteLinkHint => _isSpanish
      ? 'Pega enlace de Google Sheets o ID'
      : 'Paste Google Sheets share link or spreadsheet ID';
  String get installSharedSet =>
      _isSpanish ? 'Cargar compartido' : 'Load Shared';
  String get authorizeAndInstall =>
      _isSpanish ? 'Cargar autorizado' : 'Load Authorize';
  String get sourceDirections => _isSpanish
      ? 'Pega un enlace/ID de Google Sheets con 2 columnas: A = pregunta, B = respuesta. Usa "Cargar compartido" para hojas publicas o "Cargar autorizado" para privadas.'
      : 'Paste a Google Sheets link/ID with 2 columns: A = question, B = answer. Use "Load Shared" for public sheets or "Load Authorize" for private sheets.';
  String get collapseSource =>
      _isSpanish ? 'Ocultar fuente' : 'Collapse source';
  String get missed => _isSpanish ? 'Fallada' : 'Missed';
  String get correct => _isSpanish ? 'Correcta' : 'Correct';
  String get hide => _isSpanish ? 'Ocultar' : 'Hide';
  String get reveal => _isSpanish ? 'Mostrar' : 'Reveal';
  String get aboutDescription => _isSpanish
      ? 'Una app simple de tarjetas de estudio para sesiones con Google Sheets.'
      : 'A simple flash-card app for Google Sheets powered study sessions.';
  String get website => _isSpanish ? 'Sitio web' : 'Website';
  String get viewLicenses => _isSpanish ? 'Ver licencias' : 'View licenses';
  String get pasteLinkFirst => _isSpanish
      ? 'Primero pega un enlace de Google Sheets.'
      : 'Paste a Google Sheets share link first.';
  String get sheet => _isSpanish ? 'Hoja' : 'Sheet';
  String get noCardsFound => _isSpanish
      ? 'No se encontraron tarjetas. Verifica que las columnas A y B tengan pregunta y respuesta.'
      : 'No flash cards found. Ensure columns A and B contain question and answer.';
  String get oauthHeadersFailed => _isSpanish
      ? 'No fue posible obtener cabeceras de autorizacion de Google. Revisa OAuth.'
      : 'Unable to get Google auth headers. Check OAuth setup.';
  String get googleSignInFailed => _isSpanish
      ? 'Fallo de inicio de sesion de Google'
      : 'Google sign-in failed';
  String get loadSheetBeforeRefresh => _isSpanish
      ? 'Carga una hoja antes de actualizar.'
      : 'Load a sheet first before refreshing.';
  String get androidServerClientIdMissing => _isSpanish
      ? 'Falta configurar serverClientId de Google en Android. Inicia la app con --dart-define=GOOGLE_SERVER_CLIENT_ID=<tu_web_client_id>.apps.googleusercontent.com'
      : 'Missing Google serverClientId on Android. Start the app with --dart-define=GOOGLE_SERVER_CLIENT_ID=<your_web_client_id>.apps.googleusercontent.com';
}

enum SheetLoadMode { publicShareLink, authorized }

class InstalledDeck {
  const InstalledDeck({
    required this.name,
    required this.mode,
    required this.sourceInput,
    required this.cards,
    required this.missedCounts,
    required this.correctCounts,
  });

  final String name;
  final SheetLoadMode mode;
  final String sourceInput;
  final List<FlashCard> cards;
  final Map<String, int> missedCounts;
  final Map<String, int> correctCounts;

  String cardKey(FlashCard card) => cardKeyFor(card);

  static String cardKeyFor(FlashCard card) {
    return '${card.question.trim().toLowerCase()}||${card.answer.trim().toLowerCase()}';
  }

  InstalledDeck copyWith({
    String? name,
    SheetLoadMode? mode,
    String? sourceInput,
    List<FlashCard>? cards,
    Map<String, int>? missedCounts,
    Map<String, int>? correctCounts,
  }) {
    return InstalledDeck(
      name: name ?? this.name,
      mode: mode ?? this.mode,
      sourceInput: sourceInput ?? this.sourceInput,
      cards: cards ?? this.cards,
      missedCounts: missedCounts ?? this.missedCounts,
      correctCounts: correctCounts ?? this.correctCounts,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'mode': mode.name,
    'sourceInput': sourceInput,
    'cards': cards.map((card) => card.toJson()).toList(growable: false),
    'missedCounts': missedCounts,
    'correctCounts': correctCounts,
  };

  factory InstalledDeck.fromJson(Map<String, dynamic> json) {
    final rawCards = (json['cards'] as List<dynamic>? ?? <dynamic>[]);
    final rawMissedCounts =
        (json['missedCounts'] as Map<dynamic, dynamic>? ?? const {});
    final rawCorrectCounts =
        (json['correctCounts'] as Map<dynamic, dynamic>? ?? const {});
    return InstalledDeck(
      name: (json['name'] ?? 'Sheet').toString(),
      mode: _sheetLoadModeFromName((json['mode'] ?? '').toString()),
      sourceInput: (json['sourceInput'] ?? '').toString(),
      cards: rawCards
          .map((item) {
            if (item is Map<String, dynamic>) {
              return FlashCard.fromJson(item);
            }
            if (item is Map) {
              return FlashCard.fromJson(item.cast<String, dynamic>());
            }
            return null;
          })
          .whereType<FlashCard>()
          .toList(growable: false),
      missedCounts: rawMissedCounts.map(
        (key, value) =>
            MapEntry(key.toString(), int.tryParse(value.toString()) ?? 0),
      )..removeWhere((_, value) => value <= 0),
      correctCounts: rawCorrectCounts.map(
        (key, value) =>
            MapEntry(key.toString(), int.tryParse(value.toString()) ?? 0),
      )..removeWhere((_, value) => value <= 0),
    );
  }
}

class FlashCard {
  const FlashCard({required this.question, required this.answer});

  final String question;
  final String answer;

  Map<String, dynamic> toJson() => {'question': question, 'answer': answer};

  factory FlashCard.fromJson(Map<String, dynamic> json) {
    return FlashCard(
      question: (json['question'] ?? '').toString(),
      answer: (json['answer'] ?? '').toString(),
    );
  }
}

SheetLoadMode _sheetLoadModeFromName(String value) {
  return SheetLoadMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => SheetLoadMode.publicShareLink,
  );
}

class SheetDeckLoader {
  Future<List<FlashCard>> loadFromShareLink(String rawInput) async {
    final source = SpreadsheetSource.parse(rawInput);

    final gviz = Uri.parse(
      'https://docs.google.com/spreadsheets/d/${source.spreadsheetId}/gviz/tq?tqx=out:json&gid=${source.gid}',
    );

    final gvizResponse = await http.get(gviz);
    if (gvizResponse.statusCode == 200) {
      final cards = _parseGvizRows(gvizResponse.body);
      if (cards.isNotEmpty) return cards;
    }

    final csvUri = Uri.parse(
      'https://docs.google.com/spreadsheets/d/${source.spreadsheetId}/export?format=csv&gid=${source.gid}',
    );

    final csvResponse = await http.get(csvUri);
    if (csvResponse.statusCode != 200) {
      throw Exception(
        'Unable to load shared sheet. Verify sharing is set to "Anyone with the link".',
      );
    }

    return _parseCsvRows(csvResponse.body);
  }

  Future<List<FlashCard>> loadWithAuth(
    String rawInput,
    Map<String, String> headers,
  ) async {
    final source = SpreadsheetSource.parse(rawInput);

    String range = 'A:B';
    if (source.gid != 0) {
      final metaUri = Uri.parse(
        'https://sheets.googleapis.com/v4/spreadsheets/${source.spreadsheetId}?fields=sheets(properties(sheetId,title))',
      );

      final metaRes = await http.get(metaUri, headers: headers);
      if (metaRes.statusCode == 200) {
        final payload = jsonDecode(metaRes.body) as Map<String, dynamic>;
        final sheets = (payload['sheets'] as List<dynamic>? ?? <dynamic>[])
            .cast<Map<String, dynamic>>();
        for (final sheet in sheets) {
          final props =
              (sheet['properties'] as Map<String, dynamic>? ??
              <String, dynamic>{});
          if (props['sheetId'].toString() == source.gid.toString()) {
            final title = (props['title'] ?? '').toString().replaceAll(
              "'",
              "\\'",
            );
            if (title.isNotEmpty) {
              range = "'$title'!A:B";
            }
          }
        }
      }
    }

    final uri = Uri.parse(
      'https://sheets.googleapis.com/v4/spreadsheets/${source.spreadsheetId}/values/${Uri.encodeComponent(range)}',
    );

    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) {
      throw Exception(
        'Authorized load failed (${response.statusCode}). Check OAuth client settings and sheet permissions.',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final values = (payload['values'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (row) => (row as List<dynamic>)
              .map((cell) => cell.toString())
              .toList(growable: false),
        )
        .toList(growable: false);

    return _rowsToCards(values);
  }

  List<FlashCard> _parseCsvRows(String csvText) {
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
    ).convert(csvText);
    final values = rows
        .map(
          (row) => row.map((cell) => cell.toString()).toList(growable: false),
        )
        .toList(growable: false);
    return _rowsToCards(values);
  }

  List<FlashCard> _parseGvizRows(String body) {
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) return [];

    final jsonBody = body.substring(start, end + 1);
    final decoded = jsonDecode(jsonBody) as Map<String, dynamic>;
    final table = decoded['table'] as Map<String, dynamic>?;
    final rows = (table?['rows'] as List<dynamic>? ?? <dynamic>[]);

    final values = <List<String>>[];
    for (final row in rows) {
      final cells =
          (row as Map<String, dynamic>)['c'] as List<dynamic>? ?? <dynamic>[];
      final q = _extractGvizCell(cells, 0);
      final a = _extractGvizCell(cells, 1);
      values.add([q, a]);
    }

    return _rowsToCards(values);
  }

  String _extractGvizCell(List<dynamic> cells, int i) {
    if (i >= cells.length || cells[i] == null) return '';
    final cell = cells[i] as Map<String, dynamic>;
    final value = cell['v'];
    return value?.toString() ?? '';
  }

  List<FlashCard> _rowsToCards(List<List<String>> rows) {
    final cards = <FlashCard>[];

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final question = row.isNotEmpty ? row[0].trim() : '';
      final answer = row.length > 1 ? row[1].trim() : '';
      if (question.isEmpty || answer.isEmpty) continue;

      if (i == 0) {
        final q = question.toLowerCase();
        final a = answer.toLowerCase();
        final isHeader =
            (q == 'question' || q == 'prompt') &&
            (a == 'answer' || a == 'response');
        if (isHeader) continue;
      }

      cards.add(FlashCard(question: question, answer: answer));
    }

    return cards;
  }
}

class SpreadsheetSource {
  const SpreadsheetSource({required this.spreadsheetId, required this.gid});

  final String spreadsheetId;
  final int gid;

  static SpreadsheetSource parse(String rawInput) {
    final trimmed = rawInput.trim();

    final idOnly = RegExp(r'^[a-zA-Z0-9-_]{20,}$');
    if (idOnly.hasMatch(trimmed)) {
      return SpreadsheetSource(spreadsheetId: trimmed, gid: 0);
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      throw Exception(
        'Invalid link. Paste a full Google Sheets URL or spreadsheet ID.',
      );
    }

    final pathMatch = RegExp(
      r'/spreadsheets/d/([a-zA-Z0-9-_]+)',
    ).firstMatch(uri.path);
    if (pathMatch == null) {
      throw Exception('Could not find spreadsheet ID in the link.');
    }

    final id = pathMatch.group(1)!;
    final gidValue =
        uri.queryParameters['gid'] ??
        uri.fragment
            .split('&')
            .firstWhere(
              (part) => part.startsWith('gid='),
              orElse: () => 'gid=0',
            )
            .replaceFirst('gid=', '');

    final gid = int.tryParse(gidValue) ?? 0;
    return SpreadsheetSource(spreadsheetId: id, gid: gid);
  }
}
