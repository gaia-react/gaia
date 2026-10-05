export default String.raw`Traceback (most recent call last):
  File "importlib\resources.py", line 131, in open_text
FileNotFoundError: [Errno 2] No such file or directory: 'C:\\Users\\name\\AppData\\Local\\Temp\\_MEI64082\\jaraco\\text\\Lorem ipsum.txt'

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
  File "script.py", line 2, in <module>
    import irc.bot
  File "<frozen importlib._bootstrap>", line 991, in _find_and_load
  File "<frozen importlib._bootstrap>", line 975, in _find_and_load_unlocked
  File "<frozen importlib._bootstrap>", line 671, in _load_unlocked
  File "c:\users\name\appdata\local\programs\python\python38-32\lib\site-packages\PyInstaller\loader\pyimod03_importers.py", line 623, in exec_module
    exec(bytecode, module.__dict__)
  File "site-packages\irc\bot.py", line 21, in <module>
  File "<frozen importlib._bootstrap>", line 991, in _find_and_load
  File "<frozen importlib._bootstrap>", line 975, in _find_and_load_unlocked
  File "<frozen importlib._bootstrap>", line 671, in _load_unlocked
  File "c:\users\name\appdata\local\programs\python\python38-32\lib\site-packages\PyInstaller\loader\pyimod03_importers.py", line 623, in exec_module
    exec(bytecode, module.__dict__)
  File "site-packages\irc\dict.py", line 3, in <module>
  File "<frozen importlib._bootstrap>", line 991, in _find_and_load
  File "<frozen importlib._bootstrap>", line 975, in _find_and_load_unlocked
  File "<frozen importlib._bootstrap>", line 671, in _load_unlocked
  File "c:\users\name\appdata\local\programs\python\python38-32\lib\site-packages\PyInstaller\loader\pyimod03_importers.py", line 623, in exec_module
    exec(bytecode, module.__dict__)
  File "site-packages\jaraco\collections.py", line 9, in <module>
  File "<frozen importlib._bootstrap>", line 991, in _find_and_load
  File "<frozen importlib._bootstrap>", line 975, in _find_and_load_unlocked
  File "<frozen importlib._bootstrap>", line 671, in _load_unlocked
  File "c:\users\name\appdata\local\programs\python\python38-32\lib\site-packages\PyInstaller\loader\pyimod03_importers.py", line 623, in exec_module
    exec(bytecode, module.__dict__)
  File "site-packages\jaraco\text\__init__.py", line 232, in <module>
  File "importlib\resources.py", line 169, in read_text
  File "importlib\resources.py", line 145, in open_text
FileNotFoundError: 'Lorem ipsum.txt' resource not found in 'jaraco.text'
[25068] Failed to execute script script`;
