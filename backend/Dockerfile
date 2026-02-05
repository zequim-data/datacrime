# Usa uma imagem oficial do Python, leve e moderna
FROM python:3.11-slim

# Define a pasta de trabalho dentro do container
WORKDIR /app

# Copia o arquivo de requisitos para dentro
COPY requirements.txt .

# Instala as dependências (incluindo o pandas e o cliente do BigQuery)
RUN pip install --no-cache-dir -r requirements.txt

# Copia o código do backend para dentro
COPY main.py .

# Abre a porta 8080 (padrão do Cloud Run)
EXPOSE 8080

# Comando para rodar o servidor
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]