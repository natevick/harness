try { this.child.stdin.write("exit\n"); this.child.stdin.end(); } catch { this.broken = true; }
const timer = setTimeout(() => { if (this.child.exitCode == null && this.child.signalCode == null) { try { this.child.kill("SIGKILL"); } catch { this.broken = true; } } }, 1000);
timer.unref?.();
