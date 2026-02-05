#!/bin/bash

echo "🗑️  Limpando cache do Flutter..."
flutter clean
flutter pub get

echo "🏗️  Gerando NOVO build (Modo Moderno)..."
flutter build web --release

echo "🚀 Subindo para o Surge (Forçando atualização)..."
cd build/web
# O Surge não tem 'clear cache', então o segredo é garantir que o build/web esteja zerado antes
surge . --domain datacrime.surge.sh