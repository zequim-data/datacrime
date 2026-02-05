from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery
import uvicorn

# 1. Criação do App (Isso estava faltando no seu erro)
app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# 2. Conexão com o Banco
client = bigquery.Client(project='zecchin-analytica')

# 3. Configuração das Tabelas
CONFIG = {
    "celular": {
        "tabela": "zecchin-analytica.ssp_raw.raw_celulares_ssp",
        "col_marca": "marca_objeto",
        "col_data": "datahora_registro_bo",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    },
    "veiculo": {
        "tabela": "zecchin-analytica.ssp_raw.raw_veiculos_ssp",
        "col_marca": "descr_marca_veiculo",
        "col_data": "datahora_registro_bo",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    },
    "acidente": {
        "tabela": "zecchin-analytica.infosiga_raw.raw_sinistros",
        "col_marca": "tp_sinistro_primario",
        "col_data": "data_sinistro",
        "col_ano_num": "ano_sinistro",
        "geo_col_lat": "latitude",
        "geo_col_lon": "longitude"
    }
}

@app.get("/crimes")
def get_crimes(lat: float, lon: float, raio: int, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]
    
    # Tratamento de Coordenadas (String -> Float)
    lat_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lat']}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lon']}, ',', '.') AS FLOAT64)"

    # Filtro de Ano
    if tipo_crime == "acidente":
        # Infosiga usa ano numérico
        col_ano = f"SAFE_CAST({cfg['col_ano_num']} AS INT64)"
        if filtro == "2025": cond_ano = f"{col_ano} = 2025"
        elif filtro == "3_anos": cond_ano = f"{col_ano} >= 2023"
        else: cond_ano = f"{col_ano} >= 2021"
    else:
        # SSP usa string
        data_sql = f"SUBSTR({cfg['col_data']}, 1, 4)"
        if filtro == "2025": cond_ano = f"{data_sql} = '2025'"
        elif filtro == "3_anos": cond_ano = f"{data_sql} >= '2023'"
        else: cond_ano = f"{data_sql} >= '2021'"

    # Campos Extras (Severidade)
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
        print(f"Erro Query Crimes: {e}")
        return {"data": [], "error": str(e)}

@app.get("/detalhes")
def get_detalhes(lat: float, lon: float, filtro: str, tipo_crime: str):
    if tipo_crime not in CONFIG: return {"data": []}
    cfg = CONFIG[tipo_crime]

    lat_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lat']}, ',', '.') AS FLOAT64)"
    lon_f = f"SAFE_CAST(REPLACE({cfg['geo_col_lon']}, ',', '.') AS FLOAT64)"

    if tipo_crime == "acidente":
        # QUERY COMPLEXA (Acidentes + Veículos + Pessoas)
        query = f"""
            SELECT 
                t.tp_sinistro_primario as rubrica,
                t.logradouro as local_texto,
                t.{cfg['col_data']} as data,
                
                CASE 
                    WHEN COALESCE(SAFE_CAST(t.qtd_gravidade_fatal AS FLOAT64), 0) > 0 THEN 'FATAL' 
                    WHEN COALESCE(SAFE_CAST(t.qtd_gravidade_grave AS FLOAT64), 0) > 0 THEN 'GRAVE' 
                    ELSE 'LEVE' 
                END as severidade,

                COALESCE(SAFE_CAST(t.qtd_automovel AS INT64), 0) as autos,
                COALESCE(SAFE_CAST(t.qtd_motocicleta AS INT64), 0) as motos,
                COALESCE(SAFE_CAST(t.qtd_pedestre AS INT64), 0) as pedestres,

                -- Lista de Veículos (Blindada com CAST STRING)
                ARRAY(
                    SELECT AS STRUCT 
                        v.marca_modelo as modelo,
                        v.cor_veiculo as cor,
                        CAST(SAFE_CAST(v.ano_fab AS FLOAT64) AS INT64) as ano_fab,
                        CAST(SAFE_CAST(v.ano_modelo AS FLOAT64) AS INT64) as ano_mod,
                        v.tipo_veiculo as tipo
                    FROM `zecchin-analytica.infosiga_raw.raw_veiculos` v 
                    WHERE CAST(v.id_sinistro AS STRING) = CAST(t.id_sinistro AS STRING)
                ) as lista_veiculos,

                -- Lista de Pessoas (Blindada com CAST STRING)
                ARRAY(
                    SELECT AS STRUCT 
                        CAST(SAFE_CAST(p.idade AS FLOAT64) AS INT64) as idade,
                        p.sexo,
                        p.gravidade_lesao as lesao,
                        p.tipo_de_vitima as tipo_vitima,
                        p.tipo_veiculo_vitima as veiculo_vitima,
                        p.profissao
                    FROM `zecchin-analytica.infosiga_raw.raw_pessoas` p 
                    WHERE CAST(p.id_sinistro AS STRING) = CAST(t.id_sinistro AS STRING)
                ) as lista_pessoas

            FROM `{cfg['tabela']}` t
            WHERE {lat_f} = {lat} AND {lon_f} = {lon}
            LIMIT 50
        """
    else:
        # Lógica Simples (SSP)
        campos = ""
        if tipo_crime == "veiculo":
            campos = "descr_marca_veiculo as marca, placa_veiculo as placa, descr_cor_veiculo as cor, rubrica"
        else:
            campos = f"{cfg['col_marca']} as marca, rubrica"

        query = f"""
            SELECT {campos}, {cfg['col_data']} as data, 'Localização' as local_texto
            FROM `{cfg['tabela']}`
            WHERE {lat_f} = {lat} AND {lon_f} = {lon}
            LIMIT 50
        """

    try:
        df = client.query(query).to_dataframe()
        return {"data": df.to_dict(orient="records")}
    except Exception as e:
        print(f"ERRO CRÍTICO NO GET_DETALHES: {e}")
        return {"data": [], "error_debug": str(e)}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)