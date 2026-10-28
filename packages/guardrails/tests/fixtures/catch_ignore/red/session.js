let link; try { link = openStdio(url); } catch (err) { if (err.missingTransport) {...} failures += 1; ...; continue; }
