try {
  proc.child.kill("SIGKILL");
} catch {
  void 0; // catch-ignore-ok: the suite kills an already-exited child
}
