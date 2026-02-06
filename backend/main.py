from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn
import pandas as pd
import numpy as np
import logging

# Configuração de Logs para aparecer no painel do Cloud Run
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("API_ZECCHIN")

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

client = bigquery.Client(project='zecchin-analytica')

# CONFIGURAÇÃO: Mapeamento de tabelas e colunas
CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto",
        "col_filtro_ano": "datahora_registro_bo",
        "col_exibicao_data": "datahora_registro_bo",
        "col_local": "logradouro"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo",
        "col_filtro_ano": "datahora_registro_bo",
        "col_exibicao_data": "datahora_registro_bo",
        "col_local": "logradouro"
    },
    "acidente": {
        "tabela": "zecchin-analytica.infosiga_raw.raw_sinistros",
        "col_marca": "tp_sinistro_primario",
        "col_filtro_ano": "ano_sinistro", 
        "col_exibicao_data": "data_sinistro",
        "col_local": "logradouro"
    }
}

def sanitizar_dataframe(df):
    """Converte NaNs para None para evitar erro de JSON no FastAPI."""
    df = df.replace({np.nan: None})
    return df.to_dict(orient="records")

def get_geo_sql(campo):
    """
    Trata campos de coordenadas.
    IMPORTANTE: Seus dados têm vírgula (-22,123). O REPLACE corrige isso para ponto (-22.123).
    """
    return f"SAFE_CAST(REPLACE(CAST({campo} AS STRING), ',', '.') AS FLOAT64)"

def get_condicao_ano(filtro, col_filtro):
    """
    Gera a cláusula WHERE. 
    Resolve o problema de '2022' (string) vs 2022 (int).
    """
    if col_filtro == "ano_sinistro":
        # Converte tudo para INTEIRO antes de comparar
        # SAFE_CAST(FLOAT) previne erro se vier "2022.0"
        col_sql = f"CAST(SAFE_CAST({col_filtro} AS FLOAT64) AS INT64)"
        
        if filtro == "2025": return f"{col_sql} = 2025"
        # "3 anos" pega 2023, 2024, 2025
        if filtro == "3_anos": return f"{col_sql} >= 2023"
        # "5 anos" pega >= 2021 (Inclui seus dados de 2022!)
        if filtro == "5_anos": return f"{col_sql} >= 2021"
        
        return f"{col_sql} >= 2021"
    else:
        # Para Celular/Veículo (Data completa YYYY-MM-DD)
        ano_sql = f"SUBSTR(CAST({col_filtro} AS STRING), 1, 4)"
        if filtro == "2025": return f"{ano_sql} = '2025'"
        if filtro == "3_anos": return f"{ano_sql} >= '2023'"
        if filtro == "5_anos": return f"{ano_sql} >= '2021'"
        return f"{ano_sql} >= '2021'"

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]
    
    lat_f = get_geo_sql("latitude")
    lon_f = get_geo_sql("longitude")
    cond_ano = get_condicao_ano(filtro, cfg['col_filtro_ano'])

    extra_campos = ""
    if tipo_crime == "acidente":
        extra_campos = """, 
            CASE 
                WHEN COALESCE(SAFE_CAST(qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' 
                WHEN COALESCE(SAFE_CAST(qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' 
                ELSE 'LEVE' 
            END as severidade"""

    query = f"""
        SELECT {lat_f} as lat, {lon_f} as lon, {cfg['col_marca']} as tipo, 1 as quantidade {extra_campos}
        FROM `{cfg['tabela']}`
        WHERE {lat_f} IS NOT NULL 
          AND {cond_ano}
          AND ST_DISTANCE(ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
        LIMIT 50000
    """
    try:
        df = client.query(query).to_dataframe()
        return {"data": sanitizar_dataframe(df)}
    except Exception as e:
        logger.error(f"ERRO CRIMES: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]

    lat_f = get_geo_sql("latitude")
    lon_f = get_geo_sql("longitude")
    cond_ano = get_condicao_ano(filtro, cfg['col_filtro_ano'])

    # AUMENTO DO RAIO DE PRECISÃO (CRUCIAL PARA ACERTAR O CLIQUE)
    raio_detalhe = 50 

    if tipo_crime == "acidente":
        # A MÁGICA DO JOIN:
        # Usamos CAST(SAFE_CAST(... AS FLOAT64) AS INT64) em ambos os lados
        # Isso iguala "1830236" (string) com 1830236 (int) com "1830236.0" (float string)
        join_veiculos = "CAST(SAFE_CAST(v.id_sinistro AS FLOAT64) AS INT64) = CAST(SAFE_CAST(t.id_sinistro AS FLOAT64) AS INT64)"
        join_pessoas = "CAST(SAFE_CAST(p.id_sinistro AS FLOAT64) AS INT64) = CAST(SAFE_CAST(t.id_sinistro AS FLOAT64) AS INT64)"

        query = f"""
            SELECT 
                tp_sinistro_primario as rubrica,
                COALESCE({cfg['col_local']}, 'Local não informado') as local_texto,
                CAST({cfg['col_exibicao_data']} AS STRING) as data,
                COALESCE(SAFE_CAST(qtd_veiculo_passeio AS INT64), 0) as autos,
                COALESCE(SAFE_CAST(qtd_motocicleta AS INT64), 0) as motos,
                COALESCE(SAFE_CAST(qtd_pedestre AS INT64), 0) as pedestres,
                ARRAY(
                    SELECT AS STRUCT 
                        marca_modelo as modelo, 
                        cor_veiculo as cor, 
                        ano_fabricacao as ano_fab, 
                        tipo_veiculo as tipo
                    FROM `zecchin-analytica.infosiga_raw.raw_veiculos` v 
                    WHERE {join_veiculos}
                ) as lista_veiculos,
                ARRAY(
                    SELECT AS STRUCT 
                        CAST(SAFE_CAST(p.idade AS FLOAT64) AS INT64) as idade, 
                        sexo, 
                        descr_grau_lesao as lesao, 
                        descr_profissao as profissao, 
                        tp_envolvido as tipo_vitima
                    FROM `zecchin-analytica.infosiga_raw.raw_pessoas` p 
                    WHERE {join_pessoas}
                ) as lista_pessoas
            FROM `{cfg['tabela']}` t
            WHERE {cond_ano}
              AND ST_DISTANCE(ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio_detalhe}
            LIMIT 50
        """
    else:
        # Query para Celular/Veículos (Simplificada)
        campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica" if tipo_crime == "veiculo" else f"{cfg['col_marca']} as marca, rubrica"
        query = f"""
            SELECT {campos}, CAST({cfg['col_exibicao_data']} AS STRING) as data, COALESCE({cfg['col_local']}, 'Endereço N/I') as local_texto
            FROM `{cfg['tabela']}`
            WHERE {cond_ano}
              AND ST_DISTANCE(ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio_detalhe}
            LIMIT 50
        """

    logger.info(f"--- QUERY DETALHES ({tipo_crime}) ---")
    logger.info(query)

    try:
        df = client.query(query).to_dataframe()
        if df.empty:
            logger.warning(f"DETALHES VAZIOS! Lat: {lat}, Lon: {lon}, Filtro: {filtro}")
        return {"data": sanitizar_dataframe(df)}
    except Exception as e:
        logger.error(f"ERRO SQL DETALHES: {e}")
        return {"data": [], "error_debug": str(e)}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)