import 'dart:convert';
import 'dart:math';

import 'package:csv/csv.dart';
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
    const background = Color(0xFFF5F7FC);
    const navy = Color(0xFF1B2A41);
    const cyan = Color(0xFF00A4E4);
    const coral = Color(0xFFF25F5C);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flash Sheets',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: navy,
          primary: navy,
          secondary: cyan,
          error: coral,
          surface: Colors.white,
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

  final _linkController = TextEditingController();
  final _loader = SheetDeckLoader();
  final _googleSignIn = GoogleSignIn.instance;
  final _random = Random();

  List<InstalledDeck> _installedDecks = [];
  int? _activeDeckIndex;
  bool _showSourcePanel = false;
  bool _reverseCards = false;
  bool _reviewMissedOnly = false;
  bool _showOptionsPanel = false;

  GoogleSignInAccount? _account;
  bool _loading = false;
  String? _error;

  int _index = 0;
  int _right = 0;
  int _wrong = 0;
  bool _showAnswer = false;

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
        _showSourcePanel = false;
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
  }

  Future<void> _initializeGoogleSignIn() async {
    try {
      await _googleSignIn.initialize();

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

      final restoreAttempt = _googleSignIn.attemptLightweightAuthentication();
      if (restoreAttempt != null) {
        final user = await restoreAttempt;
        if (mounted) {
          setState(() {
            _account = user;
          });
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
    final input = _linkController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = 'Paste a Google Sheets share link first.';
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
    final input = _linkController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = 'Paste a Google Sheets share link first.';
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
    try {
      final source = SpreadsheetSource.parse(input);
      return 'Sheet ${source.spreadsheetId.substring(0, 8)}';
    } catch (_) {
      return 'Sheet';
    }
  }

  Map<String, int> _retainMissedCounts(
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
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final loaded = await action();
      if (loaded.isEmpty) {
        setState(() {
          _error =
              'No flash cards found. Ensure columns A and B contain question and answer.';
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
              : _retainMissedCounts(
                  updated[existingIndex].missedCounts,
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
        _showSourcePanel = false;
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
    try {
      final account = _account ?? await _googleSignIn.authenticate();
      final authHeaders = await account.authorizationClient
          .authorizationHeaders(const [
            'https://www.googleapis.com/auth/spreadsheets.readonly',
          ], promptIfNecessary: true);

      if (authHeaders == null) {
        setState(() {
          _error = 'Unable to get Google auth headers. Check OAuth setup.';
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
        _error = 'Google sign-in failed: $e';
      });
    }
  }

  Future<void> _refreshSheet() async {
    final deck = _activeDeck;
    if (deck == null) {
      setState(() {
        _error = 'Load a sheet first before refreshing.';
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
      _showSourcePanel = updated.isEmpty;
    });
    _persistState();
  }

  void _onCardSwipedRight() {
    if (_loading || _activeCards.isEmpty || _sessionDone) return;
    if (_showAnswer) return;
    setState(() {
      _showAnswer = true;
    });
  }

  void _onCardSwipedDown() {
    if (_loading || _activeCards.isEmpty || _sessionDone) return;
    _markCard(true);
  }

  void _onCardSwipedLeft() {
    if (_loading || _activeCards.isEmpty || _sessionDone) return;
    _markCard(false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Flash Sheets'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutPage()),
              );
            },
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: 'About',
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _showOptionsPanel = !_showOptionsPanel;
              });
            },
            icon: Icon(
              _showOptionsPanel ? Icons.tune_rounded : Icons.tune_outlined,
            ),
            tooltip: 'Options',
          ),
          if (_account != null)
            IconButton(
              onPressed: _googleSignIn.signOut,
              icon: const Icon(Icons.logout_rounded),
              tooltip: 'Sign out',
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (_showSourcePanel || _installedDecks.isEmpty) ...[
                _SourcePanel(
                  controller: _linkController,
                  loading: _loading,
                  signedInEmail: _account?.email,
                  onLoadPublic: _loadPublicSheet,
                  onLoadPrivate: _loadPrivateSheet,
                  canClose: _installedDecks.isNotEmpty,
                  onClose: () {
                    setState(() {
                      _showSourcePanel = false;
                    });
                  },
                ),
                const SizedBox(height: 16),
              ],
              if (_installedDecks.isNotEmpty) ...[
                Row(
                  children: [
                    Text(
                      'Installed sets',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _showSourcePanel = true;
                        });
                      },
                      icon: const Icon(Icons.add_rounded),
                      tooltip: 'Add new set',
                    ),
                    IconButton(
                      onPressed: _activeDeckIndex == null
                          ? null
                          : _deleteActiveDeck,
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: 'Delete selected set',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 42,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _installedDecks.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => ChoiceChip(
                      label: Text(_installedDecks[i].name),
                      selected: _activeDeckIndex == i,
                      onSelected: (_) => _switchDeck(i),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              Row(
                children: [
                  _StatChip(
                    label: 'Right',
                    value: _right,
                    color: const Color(0xFF2A9D8F),
                  ),
                  const SizedBox(width: 8),
                  _StatChip(
                    label: 'Wrong',
                    value: _wrong,
                    color: const Color(0xFFE76F51),
                  ),
                  const Spacer(),
                ],
              ),
              if (_showOptionsPanel) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _loading ? null : _refreshSheet,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Refresh'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _activeCards.isEmpty
                                  ? null
                                  : _randomizeActiveDeck,
                              icon: const Icon(Icons.shuffle_rounded),
                              label: const Text('Randomize'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _activeCards.isEmpty
                                  ? null
                                  : _resetStats,
                              icon: const Icon(Icons.restart_alt_rounded),
                              label: const Text('Reset stats'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.report_problem_outlined, size: 18),
                          const SizedBox(width: 8),
                          Text('Review missed only ($_activeMissedCount)'),
                          const Spacer(),
                          Switch(
                            value: _reviewMissedOnly,
                            onChanged: (value) {
                              setState(() {
                                _reviewMissedOnly = value;
                                _index = 0;
                                _showAnswer = false;
                              });
                              _persistState();
                            },
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const Icon(Icons.swap_horiz_rounded, size: 18),
                          const SizedBox(width: 8),
                          const Text('Reverse cards'),
                          const Spacer(),
                          Switch(
                            value: _reverseCards,
                            onChanged: (value) {
                              setState(() {
                                _reverseCards = value;
                                _showAnswer = false;
                              });
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
                              : _clearMissedForActiveDeck,
                          icon: const Icon(Icons.delete_sweep_rounded),
                          label: const Text('Clear missed records'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(child: Center(child: _buildCardArea())),
              const SizedBox(height: 12),
              _AnswerActions(
                enabled: _activeCards.isNotEmpty && !_sessionDone,
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
          ),
        ),
      ),
    );
  }

  Widget _buildCardArea() {
    if (_loading) {
      return const CircularProgressIndicator();
    }

    if (_activeDeck != null && _activeCards.isEmpty && _reviewMissedOnly) {
      return _InfoCard(
        icon: Icons.check_circle_outline_rounded,
        title: 'No missed cards',
        body: 'You are caught up. Turn off "Review missed only" to study all.',
        action: FilledButton(
          onPressed: () {
            setState(() {
              _reviewMissedOnly = false;
            });
            _persistState();
          },
          child: const Text('Study all cards'),
        ),
      );
    }

    if (_activeCards.isEmpty) {
      return _InfoCard(
        icon: Icons.table_chart_rounded,
        title: 'Load Your Sheet',
        body:
            'Use a Google Sheets share link with two columns:\nA = question, B = answer.\n\nYou can install multiple sets and switch between them.',
      );
    }

    if (_sessionDone) {
      return _InfoCard(
        icon: Icons.emoji_events_rounded,
        title: 'Session complete',
        body: 'Right: $_right\nWrong: $_wrong',
        action: FilledButton.icon(
          onPressed: _restartSession,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Restart session'),
        ),
      );
    }

    final card = _activeCards[_index];
    final frontText = _reverseCards ? card.answer : card.question;
    final backText = _reverseCards ? card.question : card.answer;
    final displayText = _showAnswer ? backText : frontText;
    final label = _showAnswer
        ? (_reverseCards ? 'Question' : 'Answer')
        : (_reverseCards ? 'Answer' : 'Question');

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity > 320) {
          _onCardSwipedRight();
        } else if (velocity < -320) {
          _onCardSwipedLeft();
        }
      },
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity > 320) {
          _onCardSwipedDown();
        }
      },
      child: AnimatedSwitcher(
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
      ),
    );
  }
}

class _SourcePanel extends StatelessWidget {
  const _SourcePanel({
    required this.controller,
    required this.loading,
    required this.signedInEmail,
    required this.onLoadPublic,
    required this.onLoadPrivate,
    required this.canClose,
    required this.onClose,
  });

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
              const Expanded(
                child: Text(
                  'Google Sheet Source',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (canClose)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Collapse source',
                ),
            ],
          ),
          if (signedInEmail != null) ...[
            const SizedBox(height: 4),
            Text(
              'Signed in as $signedInEmail',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            enabled: !loading,
            decoration: const InputDecoration(
              hintText: 'Paste Google Sheets share link or spreadsheet ID',
              prefixIcon: Icon(Icons.link_rounded),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: loading ? null : onLoadPublic,
                  icon: const Icon(Icons.public_rounded),
                  label: const Text('Install shared set'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: loading ? null : onLoadPrivate,
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Authorize & install'),
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
    required this.enabled,
    required this.onReveal,
    required this.showAnswer,
    required this.onWrong,
    required this.onRight,
  });

  final bool enabled;
  final VoidCallback onReveal;
  final bool showAnswer;
  final VoidCallback onWrong;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton(
            onPressed: enabled ? onWrong : null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE76F51),
              minimumSize: const Size.fromHeight(62),
            ),
            child: const Text('Missed', style: TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: enabled ? onReveal : null,
            icon: Icon(
              showAnswer
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              size: 28,
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(62),
            ),
            label: Text(
              showAnswer ? 'Hide' : 'Reveal',
              style: const TextStyle(fontSize: 17),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            onPressed: enabled ? onRight : null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2A9D8F),
              minimumSize: const Size.fromHeight(62),
            ),
            child: const Text('Correct', style: TextStyle(fontSize: 18)),
          ),
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
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Flash Sheets',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'A simple flash-card app for Google Sheets powered study sessions.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Website',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const SelectableText('https://hozt.com'),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () {
                showLicensePage(
                  context: context,
                  applicationName: 'Flash Sheets',
                  applicationVersion: '1.0.0',
                );
              },
              icon: const Icon(Icons.article_outlined),
              label: const Text('View licenses'),
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

enum SheetLoadMode { publicShareLink, authorized }

class InstalledDeck {
  const InstalledDeck({
    required this.name,
    required this.mode,
    required this.sourceInput,
    required this.cards,
    required this.missedCounts,
  });

  final String name;
  final SheetLoadMode mode;
  final String sourceInput;
  final List<FlashCard> cards;
  final Map<String, int> missedCounts;

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
  }) {
    return InstalledDeck(
      name: name ?? this.name,
      mode: mode ?? this.mode,
      sourceInput: sourceInput ?? this.sourceInput,
      cards: cards ?? this.cards,
      missedCounts: missedCounts ?? this.missedCounts,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'mode': mode.name,
    'sourceInput': sourceInput,
    'cards': cards.map((card) => card.toJson()).toList(growable: false),
    'missedCounts': missedCounts,
  };

  factory InstalledDeck.fromJson(Map<String, dynamic> json) {
    final rawCards = (json['cards'] as List<dynamic>? ?? <dynamic>[]);
    final rawMissedCounts =
        (json['missedCounts'] as Map<dynamic, dynamic>? ?? const {});
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
