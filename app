import streamlit as st
import pandas as pd
import numpy as np
import google.generativeai as genai
import biosteam as bst
from thermosteam import Chemicals, Stream, settings
import json

# =================================================================
# CONFIGURACIÓN Y ESTILOS
# =================================================================
st.set_page_config(page_title="BioSTEAM Process Simulation", layout="wide")

st.markdown("""
    <style>
    .metric-card {
        background-color: #ffffff;
        padding: 20px;
        border-radius: 15px;
        border-left: 5px solid #3b82f6;
        box-shadow: 0 2px 4px rgba(0,0,0,0.05);
        margin-bottom: 10px;
    }
    .metric-value { font-size: 24px; font-weight: bold; color: #1e293b; }
    .metric-label { font-size: 14px; color: #64748b; text-transform: uppercase; }
    
    /* Estilos para el Info-Box del Diagrama */
    #info-box {
        position: absolute;
        background: rgba(255, 255, 255, 0.98);
        border: 2px solid #3b82f6;
        border-radius: 10px;
        padding: 12px;
        display: none;
        z-index: 1000;
        box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1);
        pointer-events: none;
        font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        min-width: 180px;
    }
    </style>
    <div id="info-box"></div>
""", unsafe_allow_html=True)

# =================================================================
# LÓGICA DE SIMULACIÓN TÉCNICA (BIOSTEAM)
# =================================================================
def ejecutar_simulacion_tecnica(params):
    # 1. Reiniciar Flowsheet
    bst.main_flowsheet.clear()
    
    # 2. Configuración Termodinámica
    chems = Chemicals(['Water', 'Ethanol'])
    settings.set_thermo(chems)
    
    # 3. Creación de Corrientes
    mosto = Stream('mosto', Water=900, Ethanol=100, units='kg/hr', 
                    T=params['t_mosto'] + 273.15)
    
    # 4. Diseño de Equipos (Mapeo completo con el diagrama)
    # P-100: Bomba de alimentación
    P100 = bst.Pump('P100', ins=mosto, P=4*101325)
    
    # V-210: Intercambiador de pre-calentamiento
    V210 = bst.HXutility('V210', ins=P100-0, T=params['t_w220'] + 273.15)
    
    # W-310: Calentador adicional
    W310 = bst.HXutility('W310', ins=V210-0, T=params['t_w220'] + 5 + 273.15)
    
    # R-410: Tanque Flash (Separador)
    R410 = bst.Flash('R410', ins=W310-0, outs=('vapor_prod', 'liquido_residuo'), 
                     P=params['p_v100'], Q=0)
    
    # V-510: Condensador de vapor
    V510 = bst.HXutility('V510', ins=R410-0, T=40 + 273.15, V=0)
    
    # P-510: Bomba de producto condensado
    P510 = bst.Pump('P510', ins=V510-0, P=101325)
    
    # Simular Sistema
    sys = bst.System('sys_proceso', path=(P100, V210, W310, R410, V510, P510))
    sys.simulate()
    
    # 5. Diccionario de Datos para JavaScript
    datos_equipos = {
        "P-100": {"T": f"{P100.outs[0].T-273.15:.1f} °C", "P": f"{P100.outs[0].P/101325:.2f} atm", "F": f"{P100.outs[0].F_mass:.1f} kg/h"},
        "V-210": {"T": f"{V210.outs[0].T-273.15:.1f} °C", "P": f"{V210.outs[0].P/101325:.2f} atm", "F": f"{V210.outs[0].F_mass:.1f} kg/h"},
        "W-310": {"T": f"{W310.outs[0].T-273.15:.1f} °C", "P": f"{W310.outs[0].P/101325:.2f} atm", "F": f"{W310.outs[0].F_mass:.1f} kg/h"},
        "R-410": {"T": f"{R410.outs[0].T-273.15:.1f} °C", "P": f"{R410.outs[0].P/101325:.2f} atm", "F": f"{R410.outs[0].F_mass:.1f} kg/h (V)"},
        "V-510": {"T": f"{V510.outs[0].T-273.15:.1f} °C", "P": f"{V510.outs[0].P/101325:.2f} atm", "F": f"{V510.outs[0].F_mass:.1f} kg/h"},
        "P-510": {"T": f"{P510.outs[0].T-273.15:.1f} °C", "P": f"{P510.outs[0].P/101325:.2f} atm", "F": f"{P510.outs[0].F_mass:.1f} kg/h"}
    }
    
    return sys, R410.outs[0], chems, datos_equipos

# =================================================================
# COMPONENTE INTERACTIVO (SVG + JS)
# =================================================================
def render_interactive_diagram(datos_json):
    # Inyectamos el SVG con eventos onclick para cada equipo
    svg_html = f"""
    <div id="svg-container" style="background: #f8fafc; border-radius: 15px; padding: 20px;">
        <svg viewBox="0 0 800 600" width="100%" height="100%" id="process-svg">
          <style>
            .equipment {{ fill: #f0f8ff; stroke: #000080; stroke-width: 2; cursor: pointer; transition: all 0.3s; }}
            .equipment:hover {{ fill: #3b82f6; stroke-width: 3; filter: brightness(1.1); }}
            .pipe {{ fill: none; stroke: #64748b; stroke-width: 3; }}
            .label {{ font-family: 'Arial'; font-size: 14px; font-weight: bold; fill: #1e293b; pointer-events: none; }}
          </style>

          <path class="pipe" d="M 50 150 L 125 150" /> <path class="pipe" d="M 175 150 L 250 150" /> <path class="pipe" d="M 350 150 L 375 150 L 375 250 L 325 250" /> <path class="pipe" d="M 300 275 L 300 350 L 375 350" /> <path class="pipe" d="M 425 350 L 525 350" /> <path class="pipe" d="M 400 430 L 400 480" /> <path class="pipe" d="M 575 350 L 650 350" /> <g id="P-100" class="equipment" onclick="showPopup(this, 'P-100')" transform="translate(150, 150)">
            <circle cx="0" cy="0" r="25" />
            <polygon points="-10,-10 -10,10 15,0" fill="#000080"/>
            <text x="35" y="5" class="label">P-100</text>
          </g>

          <g id="V-210" class="equipment" onclick="showPopup(this, 'V-210')" transform="translate(250, 130)">
            <rect x="0" y="0" width="100" height="40" rx="20" />
            <line x1="10" y1="10" x2="90" y2="10" stroke="#000080" />
            <line x1="10" y1="30" x2="90" y2="30" stroke="#000080" />
            <text x="10" y="-10" class="label">V-210</text>
          </g>

          <g id="W-310" class="equipment" onclick="showPopup(this, 'W-310')" transform="translate(300, 250)">
            <circle cx="0" cy="0" r="25" />
            <path d="M -15 -15 L 15 15 M -15 15 L 15 -15" stroke="#000080" stroke-width="2"/>
            <text x="30" y="5" class="label">W-310</text>
          </g>

          <g id="R-410" class="equipment" onclick="showPopup(this, 'R-410')" transform="translate(400, 350)">
            <rect x="-25" y="-40" width="50" height="80" rx="10" />
            <text x="35" y="0" class="label">R-410</text>
          </g>

          <g id="V-510" class="equipment" onclick="showPopup(this, 'V-510')" transform="translate(550, 350)">
            <circle cx="0" cy="0" r="25" />
            <path d="M -15 -15 L 15 15 M -15 15 L 15 -15" stroke="#000080" stroke-width="2"/>
            <text x="30" y="5" class="label">V-510</text>
          </g>

          <g id="P-510" class="equipment" onclick="showPopup(this, 'P-510')" transform="translate(400, 500)">
            <circle cx="0" cy="0" r="20" />
            <polygon points="-8,-8 -8,8 12,0" fill="#000080"/>
            <text x="25" y="5" class="label">P-510</text>
          </g>
        </svg>
    </div>

    <script>
        const simData = {json.dumps(datos_json)};
        const box = window.parent.document.getElementById('info-box');

        function showPopup(el, id) {{
            const data = simData[id];
            const rect = el.getBoundingClientRect();
            
            box.style.display = 'block';
            box.style.left = (rect.left + window.scrollX + 50) + 'px';
            box.style.top = (rect.top + window.scrollY - 20) + 'px';
            
            box.innerHTML = `
                <div style="border-bottom:1px solid #eee; margin-bottom:8px; padding-bottom:4px;">
                    <b style="color:#3b82f6; font-size:14px;">${{id}}</b>
                </div>
                <div style="line-height:1.6;">
                    🌡️ <b>Temp:</b> ${{data.T}}<br>
                    🌀 <b>Pres:</b> ${{data.P}}<br>
                    ⚖️ <b>Flujo:</b> ${{data.F}}
                </div>
            `;
        }}

        window.parent.document.addEventListener('click', (e) => {{
            if (!e.target.closest('.equipment')) box.style.display = 'none';
        }});
    </script>
    """
    st.components.v1.html(svg_html, height=600)

# =================================================================
# INTERFAZ DE USUARIO PRINCIPAL
# =================================================================
with st.sidebar:
    st.header("⚙️ Parámetros Operativos")
    with st.expander("🌡️ Condiciones de Entrada", expanded=True):
        t_mosto = st.slider("Temp. Alimentación (°C)", 10, 60, 25)
        t_w220 = st.slider("Temp. Intercambiador (°C)", 70, 100, 92)
        p_v100 = st.slider("Presión Flash (Pa)", 50000, 150000, 101325)
    
    st.divider()
    ia_tutor = st.toggle("Asistente IA con Gemini", value=True)
    simular = st.button("🚀 Iniciar Simulación", use_container_width=True)

if simular:
    # Ejecución
    params = {'t_mosto': t_mosto, 't_w220': t_w220, 'p_v100': p_v100}
    sys, prod, chems, datos_json = ejecutar_simulacion_tecnica(params)
    
    # Dashboards de Cabecera
    st.subheader("🎯 Resultados de la Corriente de Destilado")
    c1, c2, c3, c4 = st.columns(4)
    pureza = (prod.imass['Ethanol'] / prod.F_mass * 100) if prod.F_mass > 0 else 0
    
    with c1: st.markdown(f'<div class="metric-card"><div class="metric-label">Presión</div><div class="metric-value">{prod.P/101325:.2f} atm</div></div>', unsafe_allow_html=True)
    with c2: st.markdown(f'<div class="metric-card"><div class="metric-label">Temperatura</div><div class="metric-value">{prod.T-273.15:.1f} °C</div></div>', unsafe_allow_html=True)
    with c3: st.markdown(f'<div class="metric-card"><div class="metric-label">Flujo Vapor</div><div class="metric-value">{prod.F_mass:.1f} kg/h</div></div>', unsafe_allow_html=True)
    with c4: st.markdown(f'<div class="metric-card"><div class="metric-label">Pureza Etanol</div><div class="metric-value">{pureza:.1f} %</div></div>', unsafe_allow_html=True)

    # Pestañas de Visualización
    tab1, tab2, tab3 = st.tabs(["📊 Balances de Materia", "📐 Diagrama Interactivo (PFD)", "🤖 Asistente Técnico IA"])
    
    with tab1:
        st.write("### Tabla de Corrientes del Proceso")
        data_table = []
        c_ids = [c.ID for c in chems]
        for s in sys.streams:
            row = {"ID": s.ID, "T [°C]": f"{s.T-273.15:.1f}", "P [atm]": f"{s.P/101325:.2f}", "Total [kg/h]": f"{s.F_mass:.1f}"}
            for cid in c_ids: row[cid] = f"{s.imass[cid]:.1f}"
            data_table.append(row)
        st.dataframe(pd.DataFrame(data_table), use_container_width=True)
    
    with tab2:
        st.info("💡 **Interacción:** Haz clic sobre cualquier equipo del diagrama para ver sus datos técnicos en tiempo real.")
        render_interactive_diagram(datos_json)

    with tab3:
        if ia_tutor:
            if "GEMINI_API_KEY" in st.secrets:
                genai.configure(api_key=st.secrets["GEMINI_API_KEY"])
                model = genai.GenerativeModel('gemini-1.5-flash')
                pregunta = st.text_input("Pregunta al asistente sobre el balance energético o de masa:")
                if pregunta:
                    # Contexto enriquecido para la IA
                    contexto_ia = f"Simulación BioSTEAM: Flash agua-etanol. Presión: {p_v100} Pa. Pureza obtenida: {pureza:.1f}%. "
                    respuesta = model.generate_content(contexto_ia + pregunta)
                    st.chat_message("assistant").write(respuesta.text)
            else:
                st.error("Error: Por favor configura la variable 'GEMINI_API_KEY' en el panel de Secrets de Streamlit.")
