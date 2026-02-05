from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

client = bigquery.Client(project='zecchin-analytica')

CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto",
        "col_data": "datahora_registro_bo",
        "tipo_filtro_ano": "string_substr",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo",
        "col_data": "datahora_registro_bo",
        "tipo_filtro_ano": "string_substr",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    },
    "acidente": {
        "tabela": "zecchin-analytica.infosiga_raw.raw_sinistros",
        "col_marca": "tp_sinistro_primario",
        "col_data": "data_sinistro",
        "col_ano_num": "ano_sinistro",
        "tipo_filtro_ano": "number_safe_cast", # NOVA LÓGICA: Cast seguro
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    }
}

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    
    cfg = CONFIG[tipo_crime]
    
    # 1. LATITUDE/LONGITUDE BLINDADAS
    # Garante troca de vírgula por ponto e converte string para float
    lat_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lat']}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lon']}, ',', '.') AS FLOAT64)"

    # 2. FILTRO DE ANO BLINDADO
    # Sua amostra mostra "ano_sinistro": "2022" (String). Vamos converter para INT antes de comparar.
    if cfg.get('tipo_filtro_ano') == "number_safe_cast":
        col_ano = f"SAFE_CAST({cfg['col_ano_num']} AS INT64)"
        if filtro == "2025":
            cond_ano = f"{col_ano} = 2025"
        elif filtro == "3_anos":
            cond_ano = f"{col_ano} >= 2023"
        else:
            cond_ano = f"{col_ano} >= 2021"
    else:
        # Lógica padrão para SSP
        data_sql = f"SUBSTR({cfg['col_data']}, 1, 4)"
        if filtro == "2025":
            cond_ano = f"{data_sql} = '2025'"
        elif filtro == "3_anos":
            cond_ano = f"{data_sql} >= '2023'"
        else:
            cond_ano = f"{data_sql} >= '2021'"

    # 3. SEVERIDADE BLINDADA (A MÁGICA ACONTECE AQUI)
    # COALESCE(..., 0) transforma null em 0
    # SAFE_CAST(..., FLOAT64) transforma "1.0" (string) em 1.0 (numero)
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
            {lat_f} as lat, 
            {lon_f} as lon, 
            {cfg['col_marca']} as tipo, 
            1 as quantidade 
            {extra_campos}
        FROM `{cfg['tabela']}`
        WHERE {lat_f} IS NOT NULL 
          AND {lon_f} IS NOT NULL
          AND {cond_ano}
          AND ST_DISTANCE(ST_GEOGPOINT({lon_f}, {lat_f}), ST_GEOGPOINT({lon}, {lat})) <= {raio}
        LIMIT 1000
    """
    
    try:
        df = client.query(query).to_dataframe()
        return {"data": df.to_dict(orient="records")}
    except Exception as e:
        print(f"Erro Query: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]

    lat_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lat']}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lon']}, ',', '.') AS FLOAT64)"

    campos = ""
    if tipo_crime == "veiculo":
        campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica"
    elif tipo_crime == "celular":
        campos = f"{cfg['col_marca']} as marca, rubrica"
    else: 
        # Acidente: Usamos logradouro para dar contexto
        campos = f"{cfg['col_marca']} as marca, logradouro as rubrica"
    
    query = f"""
        SELECT {campos}, {cfg['col_data']} as data, 'Localização' as local
        FROM `{cfg['tabela']}`
        WHERE {lat_f} = {lat} AND {lon_f} = {lon}
        LIMIT 50
    """
    try:
        df = client.query(query).to_dataframe()
        return {"data": df.to_dict(orient="records")}
    except Exception as e:
        return {"data": []}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)