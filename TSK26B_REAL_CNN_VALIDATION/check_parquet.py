#!/usr/bin/env python3
for pkg in ["pandas", "pyarrow", "fastparquet"]:
    try:
        __import__(pkg)
        print(f"{pkg}: available")
    except ImportError:
        print(f"{pkg}: NOT available")

