#INCLUDE "TOTVS.CH"
#INCLUDE "RESTFUL.CH"

/*/{Protheus.doc} ESTSALDOS
Demo Stock - Consulta de saldos disponibles por producto y almacen.

GET /rest/ESTSALDOS?busca=&almacen=&page=&pageSize=
Header requerido: tenantId: <empresa>,<filial>   (ej. 01,0110)

Respuesta: { status, data[], page, pageSize, total, message }
- disponible se calcula con SaldoSB2() (misma regla que valida Protheus)
- semaforo: rojo (sin disponible), amarillo (<= minimo), verde, sin_minimo
- Excluye productos bloqueados y productos con lote o ubicacion (fuera del alcance de la demo)
/*/
WSRESTFUL ESTSALDOS DESCRIPTION "Demo Stock - Saldos por producto y almacen"

	WSDATA busca    AS STRING  OPTIONAL
	WSDATA almacen  AS STRING  OPTIONAL
	WSDATA page     AS INTEGER OPTIONAL
	WSDATA pageSize AS INTEGER OPTIONAL

	WSMETHOD GET DESCRIPTION "Lista saldos con disponible y semaforo de stock minimo" WSSYNTAX "/ESTSALDOS"

END WSRESTFUL

WSMETHOD GET WSRECEIVE busca, almacen, page, pageSize WSSERVICE ESTSALDOS

	Local aArea     := GetArea()
	Local cAlias    := GetNextAlias()
	Local cBusca    := ""
	Local cLike     := ""
	Local cAlmacen  := ""
	Local nPage     := 1
	Local nPageSize := 50
	Local nDesde    := 0
	Local nHasta    := 0
	Local nFila     := 0
	Local nDisp     := 0
	Local nMin      := 0
	Local aData     := {}
	Local oItem     := Nil
	Local oResp     := JsonObject():New()
	Local cJson     := ""
	Local cOut      := ""
	Local cErro     := ""
	Local bErrOld   := ErrorBlock({|oErr| cErro := oErr:Description, Break(oErr)})

	::SetContentType("application/json;charset=utf-8")

	BEGIN SEQUENCE

		// Parametros: siempre normalizados y validados del lado servidor
		If ValType(::busca) == "C"
			cBusca := Upper(AllTrim(StrTran(::busca, "'", "")))
		EndIf
		cLike := "%" + cBusca + "%"

		If ValType(::almacen) == "C"
			cAlmacen := AllTrim(StrTran(::almacen, "'", ""))
		EndIf

		If ValType(::page) == "N" .And. ::page > 0
			nPage := Int(::page)
		EndIf

		If ValType(::pageSize) == "N" .And. ::pageSize > 0
			nPageSize := Min(Int(::pageSize), 200)
		EndIf

		nDesde := ((nPage - 1) * nPageSize) + 1
		nHasta := nPage * nPageSize

		BeginSQL Alias cAlias
			SELECT SB2.B2_COD, SB1.B1_DESC, SB1.B1_UM, SB2.B2_LOCAL, NNR.NNR_DESCRI,
			       SB2.B2_QATU, SB2.B2_RESERVA, SB2.B2_QEMP, SB1.B1_EMIN, SB1.B1_CODBAR,
			       SB2.R_E_C_N_O_ AS RECSB2
			FROM %table:SB2% SB2
			INNER JOIN %table:SB1% SB1
			        ON SB1.B1_FILIAL = %xFilial:SB1%
			       AND SB1.B1_COD    = SB2.B2_COD
			       AND SB1.%notDel%
			LEFT JOIN %table:NNR% NNR
			        ON NNR.NNR_FILIAL = %xFilial:NNR%
			       AND NNR.NNR_CODIGO = SB2.B2_LOCAL
			       AND NNR.%notDel%
			WHERE SB2.B2_FILIAL = %xFilial:SB2%
			  AND SB2.%notDel%
			  AND SB1.B1_MSBLQL <> '1'
			  AND SB1.B1_RASTRO NOT IN ('L','S')
			  AND SB1.B1_LOCALIZ <> 'S'
			  AND ( %exp:cAlmacen% = '' OR SB2.B2_LOCAL = %exp:cAlmacen% )
			  AND ( UPPER(SB1.B1_COD) LIKE %exp:cLike%
			     OR UPPER(SB1.B1_DESC) LIKE %exp:cLike%
			     OR SB1.B1_CODBAR = %exp:cBusca% )
			ORDER BY SB1.B1_DESC, SB2.B2_LOCAL
		EndSQL

		DbSelectArea("SB2")

		While (cAlias)->(!Eof())

			nFila++

			// Paginacion en AdvPL: suficiente para el volumen de la demo
			If nFila >= nDesde .And. nFila <= nHasta

				// Posiciona SB2 para que SaldoSB2() calcule el disponible real
				SB2->(DbGoTo((cAlias)->RECSB2))
				nDisp := SaldoSB2()
				nMin  := (cAlias)->B1_EMIN

				oItem := JsonObject():New()
				// RTrim y no AllTrim en claves: hay codigos con espacio inicial (ej. " CON001")
				oItem["codigo"]       := RTrim((cAlias)->B2_COD)
				oItem["descripcion"]  := AllTrim((cAlias)->B1_DESC)
				oItem["um"]           := AllTrim((cAlias)->B1_UM)
				oItem["almacen"]      := RTrim((cAlias)->B2_LOCAL)
				oItem["almacenDesc"]  := AllTrim((cAlias)->NNR_DESCRI)
				oItem["saldo"]        := (cAlias)->B2_QATU
				oItem["reservado"]    := (cAlias)->B2_RESERVA
				oItem["empenado"]     := (cAlias)->B2_QEMP
				oItem["disponible"]   := nDisp
				oItem["minimo"]       := nMin
				oItem["codigoBarras"] := AllTrim((cAlias)->B1_CODBAR)
				oItem["semaforo"]     := EstSemaforo(nDisp, nMin)

				AAdd(aData, oItem)

			EndIf

			(cAlias)->(DbSkip())

		EndDo

		oResp["status"]   := "success"
		oResp["data"]     := aData
		oResp["page"]     := nPage
		oResp["pageSize"] := nPageSize
		oResp["total"]    := nFila
		oResp["message"]  := ""

	RECOVER

		oResp := JsonObject():New()
		oResp["status"]  := "fail"
		oResp["data"]    := {}
		oResp["message"] := "Error al consultar saldos: " + AllTrim(cErro)

	END SEQUENCE

	ErrorBlock(bErrOld)

	If Select(cAlias) > 0
		(cAlias)->(DbCloseArea())
	EndIf

	cJson := oResp:ToJson()
	cOut  := EncodeUTF8(cJson)
	If ValType(cOut) <> "C"
		cOut := cJson
	EndIf

	::SetResponse(cOut)

	RestArea(aArea)

Return .T.

/*/{Protheus.doc} EstSemaforo
Clasifica el disponible frente al stock minimo (B1_EMIN).
/*/
Static Function EstSemaforo(nDisp, nMin)

	Local cRet := "sin_minimo"

	If nDisp <= 0
		cRet := "rojo"
	ElseIf nMin > 0
		cRet := IIf(nDisp <= nMin, "amarillo", "verde")
	EndIf

Return cRet
