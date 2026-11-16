DECLARE
  V_TERMINAL              VARCHAR2(15) := :P_TERMINAL;
  V_COD_OPERADORA_DOADORA VARCHAR2(15) := :P_COD_OPERADORA_DOADORA;
  V_CEP                   VARCHAR2(20) := :P_CEP;
  V_CID_CONTRATO          VARCHAR2(15) := :P_CID_CONTRATO;
  V_NUM_CONTRATO          VARCHAR2(50) := :P_NUM_CONTRATO;
  V_xml                   VARCHAR2(10000);
begin
  select '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:open="http://www.openuri.org/">' ||
         CHR(10) || ' <soapenv:Header/>' || CHR(10) || ' <soapenv:Body>' ||
         CHR(10) || ' <open:clientRequestwithReturn>' || CHR(10) ||
         ' <open:entrada>' || CHR(10) || ' <des_localid_destino>' ||
         sco.ci_nome || '</des_localid_destino>' || CHR(10) ||
         ' <des_uf_destino>' || sco.ci_estado || '</des_uf_destino>' ||
         CHR(10) || ' <num_cep_destino>' || V_CEP || '</num_cep_destino>' ||
         CHR(10) || ' <id_operadora_telefonia>' || V_COD_OPERADORA_DOADORA ||
         '</id_operadora_telefonia>' || CHR(10) || ' <ddd_telefone_voip>' ||
         substr(V_TERMINAL, 1, 2) || '</ddd_telefone_voip>' || CHR(10) ||
         ' <num_telefone_voip>' || substr(V_TERMINAL, 3, 8) ||
         '</num_telefone_voip>' || CHR(10) || ' <cid_contrato>' ||
         sco.cid_contrato || '</cid_contrato>' || CHR(10) ||
         ' <num_contrato>' || V_NUM_CONTRATO || '</num_contrato>' ||
         CHR(10) || ' </open:entrada>' || CHR(10) ||
         ' </open:clientRequestwithReturn>' || CHR(10) ||
         ' </soapenv:Body>' || CHR(10) || '</soapenv:Envelope>' XML_novo
    into V_xml
    from prod_jd.sn_contrato sc, prod_jd.sn_cidade_operadora sco
   where sco.cid_contrato = sc.cid_contrato
     and sc.num_contrato = V_NUM_CONTRATO
     and sc.cid_contrato = V_CID_CONTRATO;
  DBMS_OUTPUT.PUT_LINE(V_xml);
end;


#Exemplo de saida
{
  "msg": [
    "<soapenv:Envelope xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:open=\"http://www.openuri.org/\">",
    " <soapenv:Header/>",
    " <soapenv:Body>",
    " <open:clientRequestwithReturn>",
    " <open:entrada>",
    " <des_localid_destino>BELO HORIZONTE</des_localid_destino>",
    " <des_uf_destino>MG</des_uf_destino>",
    " <num_cep_destino>30330100</num_cep_destino>",
    " <id_operadora_telefonia>131</id_operadora_telefonia>",
    " <ddd_telefone_voip>31</ddd_telefone_voip>",
    " <num_telefone_voip>32731194</num_telefone_voip>",
    " <cid_contrato>25666</cid_contrato>",
    " <num_contrato>19908806</num_contrato>",
    " </open:entrada>",
    " </open:clientRequestwithReturn>",
    " </soapenv:Body>",
    "</soapenv:Envelope>"
  ],
  "_ansible_verbose_always": true,
  "_ansible_no_log": null,
  "changed": false
}