from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn
import pandas as pd
import numpy as np
import logging
import json

# Configuração de Logs
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
        "col_filtro_ano": "dt_particao",
        "col_exibicao_data": "datahora_registro_bo",
        "col_local": "logradouro"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo",
        "col_filtro_ano": "dt_particao",
        "col_exibicao_data": "datahora_registro_bo",
        "col_local": "logradouro"
    },
    "acidente": {
        "tabela": "zecchin-analytica.infosiga_raw.raw_sinistros",
        "col_marca": "tp_sinistro_primario",
        "col_filtro_ano": "dt_particao", 
        "col_exibicao_data": "data_sinistro",
        "col_local": "logradouro"
    },
    "criminal": {
        "tabela": "zecchin-analytica.ssp_raw.raw_dados_criminais_ssp",
        "col_marca": "natureza_apurada",
        "col_filtro_ano": "dt_particao",
        "col_exibicao_data": "data_ocorrencia_bo",
        "col_local": "logradouro"
    }
}

def sanitizar_dataframe(df):
    try:
        if df.empty: return []
        json_str = df.to_json(orient="records", date_format="iso")
        return json.loads(json_str)
    except Exception as e:
        logger.error(f"ERRO SANITIZACAO: {e}")
        return []

def get_geo_sql(campo):
    return f"SAFE_CAST(REPLACE(CAST({campo} AS STRING), ',', '.') AS FLOAT64)"

def get_condicao_ano(filtro, col_filtro):
    # Agora que col_filtro é sempre 'dt_particao' (um DATE real)
    # usamos EXTRACT para máxima performance no particionamento
    sql_ano = f"EXTRACT(YEAR FROM {col_filtro})"
    
    if filtro == "2025":
        return f"{sql_ano} = 2025"
    if filtro == "3_anos":
        return f"{sql_ano} >= 2023"
    if filtro == "5_anos":
        return f"{sql_ano} >= 2021"
    
    return f"{sql_ano} >= 2021"

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]
    
    lat_f = get_geo_sql("latitude")
    lon_f = get_geo_sql("longitude")
    cond_ano = get_condicao_ano(filtro, cfg['col_filtro_ano'])

    extra_campos = ""
    if tipo_crime == "acidente":
        extra_campos = """, CASE WHEN COALESCE(SAFE_CAST(qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' WHEN COALESCE(SAFE_CAST(qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' ELSE 'LEVE' END as severidade"""

    query = f"""
        SELECT {lat_f} as lat, {lon_f} as lon, {cfg['col_marca']} as tipo, 1 as quantidade {extra_campos}
        FROM `{cfg['tabela']}`
        WHERE {lat_f} IS NOT NULL AND {lat_f} BETWEEN -90 AND 90 AND {lon_f} BETWEEN -180 AND 180 AND {cond_ano}
          AND ST_DISTANCE(SAFE.ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
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
    lat_f, lon_f = get_geo_sql("latitude"), get_geo_sql("longitude")
    cond_ano = get_condicao_ano(filtro, cfg['col_filtro_ano'])
    raio_detalhe = 2 

    if tipo_crime == "acidente":
        join_veiculos = f"v.dt_particao >= '2021-01-01' AND CAST(SAFE_CAST(v.id_sinistro AS FLOAT64) AS INT64) = CAST(SAFE_CAST(t.id_sinistro AS FLOAT64) AS INT64)"
        join_pessoas = f"p.dt_particao >= '2021-01-01' AND CAST(SAFE_CAST(p.id_sinistro AS FLOAT64) AS INT64) = CAST(SAFE_CAST(t.id_sinistro AS FLOAT64) AS INT64)"
        query = f"""
            SELECT tp_sinistro_primario as rubrica, COALESCE({cfg['col_local']}, 'Local não informado') as local_texto, CAST({cfg['col_exibicao_data']} AS STRING) as data,
                   COALESCE(SAFE_CAST(qtd_automovel AS INT64), 0) as autos, COALESCE(SAFE_CAST(qtd_motocicleta AS INT64), 0) as motos,
                   COALESCE(SAFE_CAST(qtd_pedestre AS INT64), 0) as pedestres, COALESCE(SAFE_CAST(qtd_bicicleta AS INT64), 0) as bikes,
                   COALESCE(SAFE_CAST(qtd_onibus AS INT64), 0) as onibus, COALESCE(SAFE_CAST(qtd_caminhao AS INT64), 0) as caminhoes,
                   COALESCE(SAFE_CAST(qtd_veic_outros AS INT64), 0) as outros,
                   ARRAY(SELECT AS STRUCT marca_modelo as modelo, cor_veiculo as cor, CAST(ano_fab AS STRING) as ano_fab, tipo_veiculo as tipo FROM `zecchin-analytica.infosiga_raw.raw_veiculos` v WHERE {join_veiculos}) as lista_veiculos,
                   ARRAY(SELECT AS STRUCT CAST(SAFE_CAST(p.idade AS FLOAT64) AS INT64) as idade, sexo, gravidade_lesao as lesao, profissao as profissao, tipo_de_vitima as tipo_vitima FROM `zecchin-analytica.infosiga_raw.raw_pessoas` p WHERE {join_pessoas}) as lista_pessoas
            FROM `{cfg['tabela']}` t
            WHERE {cond_ano} AND {lat_f} BETWEEN -90 AND 90 AND ST_DISTANCE(SAFE.ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio_detalhe}
            LIMIT 50
        """
    else:
        campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica" if tipo_crime == "veiculo" else f"{cfg['col_marca']} as marca, rubrica"
        query = f"""
            SELECT {campos}, CAST({cfg['col_exibicao_data']} AS STRING) as data, COALESCE({cfg['col_local']}, 'Endereço N/I') as local_texto
            FROM `{cfg['tabela']}`
            WHERE {cond_ano} AND {lat_f} BETWEEN -90 AND 90 AND ST_DISTANCE(SAFE.ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio_detalhe}
            LIMIT 50
        """
    try:
        df = client.query(query).to_dataframe()
        return {"data": sanitizar_dataframe(df)}
    except Exception as e:
        return {"data": [], "error_debug": str(e)}

# --- NOVA FUNCIONALIDADE: COMPARAÇÃO ---
def get_contagem_local(lat, lon, raio, filtro):
    """Conta ocorrências num raio específico para todas as categorias."""
    stats = {}
    categorias = ["celular", "veiculo", "criminal", "acidente"]
    
    for cat in categorias:
        if cat not in CONFIG: continue
        cfg = CONFIG[cat]
        lat_f = get_geo_sql("latitude")
        lon_f = get_geo_sql("longitude")
        cond_ano = get_condicao_ano(filtro, cfg['col_filtro_ano'])
        
        query = f"""
            SELECT COUNT(*) as total
            FROM `{cfg['tabela']}`
            WHERE {cond_ano}
              AND {lat_f} BETWEEN -90 AND 90 
              AND ST_DISTANCE(SAFE.ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
        """
        try:
            df = client.query(query).to_dataframe()
            stats[cat] = int(df['total'][0]) if not df.empty else 0
        except Exception as e:
            logger.error(f"Erro contagem {cat}: {e}")
            stats[cat] = 0
            
    return stats

@app.get("/comparar")
def comparar_locais(lat1: float, lon1: float, lat2: float, lon2: float, filtro: str = "2025"):
    # Raio fixo de 500m para comparação de vizinhança
    raio_comparacao = 500
    
    dados_a = get_contagem_local(lat1, lon1, raio_comparacao, filtro)
    dados_b = get_contagem_local(lat2, lon2, raio_comparacao, filtro)
    
    total_a = sum(dados_a.values())
    total_b = sum(dados_b.values())
    
    return {
        "local_a": dados_a,
        "local_b": dados_b,
        "total_a": total_a,
        "total_b": total_b,
        "raio": raio_comparacao
    }
if __name__ == "__main__":
    import os
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run(app, host="0.0.0.0", port=port)