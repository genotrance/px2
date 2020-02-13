import osproc

doAssert execCmd("nim c src/px2") == 0
doAssert execCmd("nim c --threads:on src/px2") == 0