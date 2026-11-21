import 'package:flutter/foundation.dart';

/// Counts management exchanges with the repeater in one session so the mesh
/// cost of an action is visible. A soft budget warning is opt-in: null means
/// no warning, and the meter keeps counting either way.
class RequestMeter extends ChangeNotifier {
  RequestMeter({this.budget});

  /// Null disables the warning. Set through App settings, never persisted.
  int? budget;

  int _count = 0;
  int get count => _count;

  bool get overBudget => budget != null && _count >= budget!;

  /// Set to true once the warning has been noticed so it does not nag on every
  /// rebuild; a reset clears it.
  bool warningShown = false;

  void record([int amount = 1]) {
    if (amount <= 0) return;
    _count += amount;
    notifyListeners();
  }

  void setBudget(int? value) {
    if (value != null && value < 1) value = 1;
    if (budget == value) return;
    budget = value;
    warningShown = false;
    notifyListeners();
  }

  void reset() {
    if (_count == 0 && !warningShown) return;
    _count = 0;
    warningShown = false;
    notifyListeners();
  }
}
