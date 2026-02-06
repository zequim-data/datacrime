from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn
import numpy as np

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

client = bigquery.Client(project='zecchin-analytica')

# CONFIGURAÇÃO UNIFICADA - CRITÉRIO: col_data é a fonte da verdade
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

# QUERY TRACKER: Função para extrair o ano de qualquer formato de data
def get_condicao_ano(filtro, col_data):
    # Transforma qualquer data em STRING e pega os 4 primeiros dígitos (YYYY)
    ano_sql = f"SUBSTR(CAST({col_data} AS STRING), 1, 4)"
    if filtro == "2025": return f"{ano_sql} = '2025'"
    if filtro == "3_anos": return f"{ano_sql} >= '2023'"
    return f"{ano_sql} >= '2021'"

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    print(f"\n--- [QUERY TRACKER: INÍCIO] ---")
    print(f"Buscando: {tipo_crime} | Filtro: {filtro} | Raio: {raio}m")
    
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]
    cond_ano = get_condicao_ano(filtro, cfg['col_data'])
    
    # ESCUDO GEOGRÁFICO: Trata vírgulas e limpa espaços
    lat_f = f"SAFE_CAST(REPLACE(TRIM(latitude), ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE(TRIM(longitude), ',', '.') AS FLOAT64)"

    # Adicionado severidade apenas para acidentes
    extra = ""
    if tipo_crime == "acidente":
        extra = """, CASE 
            WHEN COALESCE(SAFE_CAST(qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' 
            WHEN COALESCE(SAFE_CAST(qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' 
            ELSE 'LEVE' END as severidade"""

    query = f"""
        SELECT 
            {lat_f} as lat, {lon_f} as lon, 
            {cfg['col_marca']} as tipo, 1 as quantidade {extra}
        FROM `{cfg['tabela']}`
        WHERE {lat_f} BETWEEN -90 AND 90   -- FILTRO DE SEGURANÇA
          AND {lon_f} BETWEEN -180 AND 180 -- FILTRO DE SEGURANÇA
          AND {cond_ano}
          -- SAFE.ST_GEOGPOINT evita o erro 400 se o dado for podre
          AND ST_DISTANCE(SAFE.ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
        LIMIT 1000
    """
    
    print(f"SQL EXECUTADA:\n{query}\n") # Tracker de Query no Terminal
    
    try:
        df = client.query(query).to_dataframe().replace({np.nan: None})
        return {"data": df.to_dict(orient="records")}
    except Exception as e:
        print(f"ERRO BIGQUERY: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    cfg = CONFIG[tipo_crime]
    cond_ano = get_condicao_ano(filtro, cfg['col_data'])
    
    lat_f = f"SAFE_CAST(REPLACE(latitude, ',', '.') AS FLOAT64)"
    
    if tipo_crime == "acidente":
        # Detalhes ricos para acidentes (JOINs do Infosiga)
        query = f"""
            SELECT tp_sinistro_primario as rubrica, {cfg['col_data']} as data, logradouro as local_texto,
            ARRAY(SELECT AS STRUCT marca_modelo as modelo, cor_veiculo as cor FROM `zecchin-analytica.infosiga_raw.raw_veiculos` v WHERE CAST(v.id_sinistro AS STRING) = CAST(t.id_sinistro AS STRING)) as lista_veiculos
            FROM `{cfg['tabela']}` t WHERE {lat_f} = {lat} AND {cond_ano} LIMIT 50
        """
    else:
        campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica" if tipo_crime == "veiculo" else f"{cfg['col_marca']} as marca, rubrica"
        query = f"""
            SELECT {campos}, CAST({cfg['col_data']} AS STRING) as data, COALESCE(logradouro, 'N/I') as local_texto
            FROM `{cfg['tabela']}` WHERE {lat_f} = {lat} AND {cond_ano} LIMIT 50
        """
    
    df = client.query(query).to_dataframe().replace({np.nan: None})
    return {"data": df.to_dict(orient="records")}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)