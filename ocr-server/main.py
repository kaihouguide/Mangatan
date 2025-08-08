"""This file is used for Nuitka configuration"""
# nuitka-project: --standalone
# nuitka-project: --output-filename=mangatan-server.exe
# nuitka-project-if: {OS} == "Windows":
#    nuitka-project: --include-package=oneocr
# nuitka-project: --python-flag=-O

if __name__ == "__main__":
    from server import main

    main()
