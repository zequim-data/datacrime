from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

client = bigquery.Client(project='zecchin-analytica')

# Mapeamento de Tabelas e Colunas
CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo"
    }
}

def get_condicao_ano(filtro: str):
    data_sql = "SUBSTR(datahora_registro_bo,1,4)"
    if filtro == "2025": return f"{data_sql} = '2025'"
    if filtro == "3_anos": return f"{data_sql} >= '2023'"
    if filtro == "5_anos": return f"{data_sql} >= '2021'"
    return f"{data_sql} = '2025'"

@app.get("/crimes")
async def get_crimes(lat: float, lon: float, raio: int, filtro: str = "2025", tipo_crime: str = "celular"):
    cfg = CONFIG.get(tipo_crime, CONFIG["celular"])
    condicao_ano = get_condicao_ano(filtro)
    
    query = f"""
        SELECT 
            CAST(latitude AS STRING) as lat, 
            CAST(longitude AS STRING) as lon, 
            COALESCE({cfg['col_marca']}, 'OUTROS') as tipo
        FROM `{cfg['tabela']}`
        WHERE {condicao_ano}
        AND ST_DWithin(
            ST_GeogPoint(SAFE_CAST(longitude AS FLOAT64), SAFE_CAST(latitude AS FLOAT64)), 
            ST_GeogPoint({lon}, {lat}), 
            {raio}
        )
        LIMIT 50000 -- Reduzido para evitar travamento no mobile
    """
    try:
        query_job = client.query(query)
        return {"data": [dict(row) for row in query_job.result()]}
    except Exception as e:
        return {"data": [], "erro": str(e)}

@app.get("/detalhes")
async def get_detalhes(lat: float, lon: float, filtro: str = "2025", tipo_crime: str = "celular"):
    cfg = CONFIG.get(tipo_crime, CONFIG["celular"])
    condicao_ano = get_condicao_ano(filtro)
    
    # Colunas específicas para veículos se for o caso
    extra_cols = ""
    if tipo_crime == "veiculo":
        extra_cols = ", ifnull(placa_veiculo, 'N/D') as placa, ifnull(descr_cor_veiculo, 'N/D') as cor"

    query = f"""
        SELECT DISTINCT
            SUBSTR(data_ocorrencia_bo,1,10) as data, 
            ifnull(hora_ocorrencia,'N/D') as hora, 
            ifnull(descr_periodo,'N/D') as periodo,
            ifnull({cfg['col_marca']},'N/D') as marca, 
            ifnull(descr_conduta,'N/D') as conduta, 
            ifnull(rubrica,'N/D') as rubrica, 
            ifnull(descr_subtipolocal,'N/D') as local
            {extra_cols}
        FROM `{cfg['tabela']}`
        WHERE {condicao_ano}
        AND ST_DWithin(
            ST_GeogPoint(SAFE_CAST(longitude AS FLOAT64), SAFE_CAST(latitude AS FLOAT64)), 
            ST_GeogPoint({lon}, {lat}), 
            2 -- Raio de tolerância de 2m para agrupamento
        )
        ORDER BY data DESC LIMIT 50
    """
    try:
        query_job = client.query(query)
        return {"data": [dict(row) for row in query_job.result()]}
    except Exception as e:
        return {"data": [], "erro": str(e)}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)