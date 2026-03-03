class DialogState {
  DialogState({this.maxHistory = 6});

  final int maxHistory;
  final Map<String, String> slots = {};
  final List<String> userHistory = [];
  final List<String> agentHistory = [];
  int turn = 0;

  void addUser(String text) {
    turn += 1;
    userHistory.add(text);
    _trim(userHistory);
  }

  void addAgent(String text) {
    agentHistory.add(text);
    _trim(agentHistory);
  }

  String? lastUser() => userHistory.isEmpty ? null : userHistory.last;
  String? lastAgent() => agentHistory.isEmpty ? null : agentHistory.last;

  void _trim(List<String> list) {
    if (list.length <= maxHistory) return;
    list.removeRange(0, list.length - maxHistory);
  }
}
