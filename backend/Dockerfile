FROM python:3.11-slim
WORKDIR /app

# Copia os arquivos da PRÓPRIA pasta (backend) para o container
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]