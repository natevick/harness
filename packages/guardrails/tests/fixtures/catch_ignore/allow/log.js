try {
  child.kill("SIGKILL");
} catch (err) {
  console.error(err);
}
