from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

client = bigquery.Client(project='zecchin-analytica')

# --- CONFIGURAÇÃO EXATA BASEADA NO SEU DDL ---
CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto",
        "col_data": "datahora_registro_bo",
        "tipo_filtro_ano": "string_substr", # SSP usa data string
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
        "tabela": "zecchin-analytica.infosiga.raw_sinistros",
        "col_marca": "tp_sinistro_primario", # Ex: Colisão, Atropelamento
        "col_data": "data_sinistro",           # Para exibir na tela
        "col_ano_num": "ano_sinistro",         # TRUNFO: Campo numérico para filtro rápido
        "tipo_filtro_ano": "number_direct",    # Flag para usar lógica numérica
        "geo_col_lat": "latitude",             # É STRING no seu DDL
        "geo_col_lon": "longitude"             # É STRING no seu DDL
    }
}

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    
    cfg = CONFIG[tipo_crime]
    
    # 1. TRATAMENTO DE GEOLOCALIZAÇÃO (CRÍTICO)
    # Como o DDL diz que é STRING, prevenimos erro de vírgula (comum no BR) trocando por ponto
    col_lat = cfg['geo_col_lat']
    col_lon = cfg['geo_col_lon']
    
    # SAFE_CAST(REPLACE(latitude, ',', '.') AS FLOAT64) garante que funcione para "-23.5" ou "-23,5"
    lat_f = f"SAFE_CAST(REPLACE({col_lat}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({col_lon}, ',', '.') AS FLOAT64)"

    # 2. LÓGICA DE FILTRO DE ANO
    if cfg['tipo_filtro_ano'] == "number_direct":
        # Lógica otimizada para o INFOSIGA (raw_sinistros)
        col_ano = cfg['col_ano_num']
        if filtro == "2025":
            cond_ano = f"{col_ano} = 2025"
        elif filtro == "3_anos":
            cond_ano = f"{col_ano} >= 2023"
        else:
            cond_ano = f"{col_ano} >= 2021"
    else:
        # Lógica legado para SSP (raw_celulares/veiculos)
        col_data = cfg['col_data']
        # Pega os primeiros 4 chars (YYYY) da string de data
        data_sql = f"SUBSTR({col_data}, 1, 4)"
        if filtro == "2025":
            cond_ano = f"{data_sql} = '2025'"
        elif filtro == "3_anos":
            cond_ano = f"{data_sql} >= '2023'"
        else:
            cond_ano = f"{data_sql} >= '2021'"

    # 3. CAMPOS EXTRAS (SEVERIDADE PARA ACIDENTES)
    extra_campos = ""
    if tipo_crime == "acidente":
        # Baseado no seu DDL, calculamos a severidade para pintar a bolinha
        extra_campos = """, 
            CASE 
                WHEN qtd_gravidade_fatal > 0 THEN 'FATAL' 
                WHEN qtd_gravidade_grave > 0 THEN 'GRAVE' 
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
        print(f"ERRO QUERY: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]

    # Recalcula lat_f/lon_f para o WHERE exato
    col_lat = cfg['geo_col_lat']
    col_lon = cfg['geo_col_lon']
    lat_f = f"SAFE_CAST(REPLACE({col_lat}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({col_lon}, ',', '.') AS FLOAT64)"

    # Campos específicos para exibição na "gaveta"
    campos = ""
    if tipo_crime == "veiculo":
        campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica"
    elif tipo_crime == "celular":
        campos = f"{cfg['col_marca']} as marca, rubrica"
    else: 
        # Acidente (Infosiga não tem rubrica ou placa no DDL principal)
        # Usamos o logradouro para dar mais contexto
        campos = f"{cfg['col_marca']} as marca, logradouro as rubrica"
    
    # Nota: Usamos LIMIT 50 para evitar sobrecarga, pois coordenadas exatas podem ter duplicatas
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
        print(f"ERRO DETALHES: {e}")
        return {"data": []}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)