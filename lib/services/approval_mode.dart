enum ApprovalMode {
  askForApproval,
  approveForMe,
  fullAccess;

  static ApprovalMode fromStorage(String? value) {
    for (final mode in ApprovalMode.values) {
      if (mode.name == value) return mode;
    }
    return ApprovalMode.askForApproval;
  }
}
