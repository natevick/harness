this.child.stdin.end("exit\n");
const timer = setTimeout(() => this.child.kill("SIGKILL"), 1000);
timer.unref();
