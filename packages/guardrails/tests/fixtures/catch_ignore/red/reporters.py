def junit_plugin(config):
    try:
        from _pytest.junitxml import xml_key
        found = config.stash.get(xml_key, None)
        if found is not None:
            return found
    except Exception:
        pass
