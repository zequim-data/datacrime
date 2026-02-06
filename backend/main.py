from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn
import numpy as np

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

client = bigquery.Client(project='zecchin-analytica')

# CONFIGURAÇÃO UNIFICADA - CRITÉRIO: col_data é a chave mestra
CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto",
        "col_data": "datahora_registro_bo",
        "col_local": "logradouro"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo",
        "col_data": "datahora_registro_bo",
        "col_local": "logradouro"
    },
    "acidente": {
        "tabela": "zecchin-analytica.infosiga_raw.raw_sinistros",
        "col_marca": "tp_sinistro_primario",
        "col_data": "data_sinistro",
        "col_local": "logradouro"
    }
}

# QUERY TRACKER: Função para gerar a condição de ano de forma segura
def get_condicao_ano(filtro, col_data):
    # Extrai YYYY da string de data (funciona para SSP e Infosiga)
    ano_sql = f"SUBSTR(CAST({col_data} AS STRING), 1, 4)"
    if filtro == "2025": return f"{ano_sql} = '2025'"
    if filtro == "3_anos": return f"{ano_sql} >= '2023'"
    return f"{ano_sql} >= '2021'" # 5 anos ou padrão

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    print(f"\n--- [QUERY TRACKER: INÍCIO DA BUSCA] ---")
    print(f"Parâmetros Recebidos: Tipo={tipo_crime}, Filtro={filtro}, Raio={raio}m")
    
    if tipo_crime not in CONFIG:
        print(f"ERRO: Categoria '{tipo_crime}' não mapeada no CONFIG!")
        return {"data": []}
    
    cfg = CONFIG[tipo_crime]
    cond_ano = get_condicao_ano(filtro, cfg['col_data'])
    
    # Tratamento geográfico universal
    lat_f = f"SAFE_CAST(REPLACE(latitude, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE(longitude, ',', '.') AS FLOAT64)"

    extra_campos = ""
    if tipo_crime == "acidente":
        extra_campos = """, 
            CASE 
                WHEN COALESCE(SAFE_CAST(qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' 
                WHEN COALESCE(SAFE_CAST(qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' 
                ELSE 'LEVE' 
            END as severidade"""

    query = f"""
        SELECT 
            {lat_f} as lat, {lon_f} as lon, 
            {cfg['col_marca']} as tipo, 1 as quantidade {extra_campos}
        FROM `{cfg['tabela']}`
        WHERE {lat_f} IS NOT NULL AND {cond_ano}
          AND ST_DISTANCE(ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
        LIMIT 1000
    """
    
    print(f"SQL EXECUTADA:\n{query}\n") # O seu Tracker de Query
    
    try:
        df = client.query(query).to_dataframe().replace({np.nan: None})
        results = df.to_dict(orient="records")
        print(f"RESULTADO: {len(results)} registros encontrados.")
        print(f"--- [QUERY TRACKER: FIM] ---\n")
        return {"data": results}
    except Exception as e:
        print(f"ERRO CRÍTICO NO BIGQUERY: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    # Lógica simplificada para bater com o get_crimes
    cfg = CONFIG[tipo_crime]
    cond_ano = get_condicao_ano(filtro, cfg['col_data'])
    
    campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica" if tipo_crime == "veiculo" else f"{cfg['col_marca']} as marca, 'OCORRÊNCIA' as rubrica"
    
    query = f"""
        SELECT {campos}, CAST({cfg['col_data']} AS STRING) as data, COALESCE(logradouro, 'Endereço N/I') as local_texto
        FROM `{cfg['tabela']}`
        WHERE SAFE_CAST(REPLACE(latitude, ',', '.') AS FLOAT64) = {lat} AND {cond_ano}
        LIMIT 50
    """
    df = client.query(query).to_dataframe().replace({np.nan: None})
    return {"data": df.to_dict(orient="records")}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)