from _pytest.junitxml import xml_key


def junit_plugin(config):
    return config.stash.get(xml_key, None)
