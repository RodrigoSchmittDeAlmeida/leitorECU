"""Configuração do pytest e fixtures compartilhadas."""
import os
import sys
import pytest

# Adiciona o diretório raiz ao sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

