from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn
import pandas as pd
import numpy as np

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

client = bigquery.Client(project='zecchin-analytica')

# CONFIGURAÇÃO UNIFICADA
CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto",
        "col_data": "datahora_registro_bo",
        "col_local": "logradouro",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo",
        "col_data": "datahora_registro_bo",
        "col_local": "logradouro",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    },
    "acidente": {
        "tabela": "zecchin-analytica.infosiga_raw.raw_sinistros",
        "col_marca": "tp_sinistro_primario",
        "col_data": "data_sinistro",
        "col_local": "logradouro",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    }
}

def sanitizar_dataframe(df):
    df = df.replace({np.nan: None})
    return df.to_dict(orient="records")

# FUNÇÃO DE FILTRO CORRIGIDA (CRITÉRIO: SUBSTR PARA TUDO)
def get_condicao_ano(filtro, col_data):
    ano_sql = f"SUBSTR(CAST({col_data} AS STRING), 1, 4)"
    if filtro == "2025":
        return f"{ano_sql} = '2025'"
    elif filtro == "3_anos":
        return f"{ano_sql} >= '2023'"
    else: # 5 anos ou padrão
        return f"{ano_sql} >= '2021'"

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]
    
    lat_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lat']}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lon']}, ',', '.') AS FLOAT64)"
    
    # Aplica o filtro de ano usando a nova lógica unificada
    cond_ano = get_condicao_ano(filtro, cfg['col_data'])

    extra_campos = ""
    if tipo_crime == "acidente":
        extra_campos = """, 
            CASE 
                WHEN COALESCE(SAFE_CAST(qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' 
                WHEN COALESCE(SAFE_CAST(t.qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' 
                ELSE 'LEVE' 
            END as severidade"""

    query = f"""
        SELECT 
            {lat_f} as lat, 
            {lon_f} as lon, 
            {cfg['col_marca']} as tipo, 
            1 as quantidade 
            {extra_campos}
        FROM `{cfg['tabela']}` t
        WHERE {lat_f} IS NOT NULL 
          AND {lon_f} IS NOT NULL
          AND {cond_ano}
          AND ST_DISTANCE(ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
        LIMIT 50000
    """
    
    try:
        df = client.query(query).to_dataframe()
        return {"data": sanitizar_dataframe(df)}
    except Exception as e:
        print(f"Erro Query Crimes: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]

    lat_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lat']}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lon']}, ',', '.') AS FLOAT64)"
    cond_ano = get_condicao_ano(filtro, cfg['col_data'])

    if tipo_crime == "acidente":
        query = f"""
            SELECT 
                t.tp_sinistro_primario as rubrica,
                COALESCE(t.{cfg['col_local']}, 'Local não informado') as local_texto,
                CAST(t.{cfg['col_data']} AS STRING) as data,
                CASE 
                    WHEN COALESCE(SAFE_CAST(t.qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' 
                    WHEN COALESCE(SAFE_CAST(t.qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' 
                    ELSE 'LEVE' 
                END as severidade,
                ARRAY(
                    SELECT AS STRUCT v.marca_modelo as modelo, v.cor_veiculo as cor, CAST(SAFE_CAST(v.ano_fab AS FLOAT64) AS INT64) as ano_fab, v.tipo_veiculo as tipo
                    FROM `zecchin-analytica.infosiga_raw.raw_veiculos` v 
                    WHERE CAST(v.id_sinistro AS STRING) = CAST(t.id_sinistro AS STRING)
                ) as lista_veiculos,
                ARRAY(
                    SELECT AS STRUCT CAST(SAFE_CAST(p.idade AS FLOAT64) AS INT64) as idade, p.sexo, p.gravidade_lesao as lesao, p.tipo_de_vitima as tipo_vitima, p.profissao
                    FROM `zecchin-analytica.infosiga_raw.raw_pessoas` p 
                    WHERE CAST(p.id_sinistro AS STRING) = CAST(t.id_sinistro AS STRING)
                ) as lista_pessoas
            FROM `{cfg['tabela']}` t
            WHERE {lat_f} = {lat} AND {lon_f} = {lon} AND {cond_ano}
            LIMIT 500
        """
    else:
        campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica" if tipo_crime == "veiculo" else f"{cfg['col_marca']} as marca, rubrica"
        query = f"""
            SELECT {campos}, CAST({cfg['col_data']} AS STRING) as data, COALESCE({cfg['col_local']}, 'Endereço não informado') as local_texto
            FROM `{cfg['tabela']}`
            WHERE {lat_f} = {lat} AND {lon_f} = {lon} AND {cond_ano}
            LIMIT 500
        """

    try:
        query_job = client.query(query)
        results = [dict(row) for row in query_job]
        return {"data": results}
    except Exception as e:
        return {"data": [], "error_debug": str(e)}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)