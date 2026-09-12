<#assign navActive = "procedures">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>시술 상세 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page admin-detail">
    <section class="page-title">
        <p class="eyebrow">PROCEDURE #${procedure.id}</p>
        <h1>${procedure.name?html}</h1>
        <p><a class="back-link" href="/admin/procedures">← 시술 목록</a></p>
    </section>

    <section class="content-band admin-detail-grid">
        <div class="panel">
            <h2>시술 정보 수정</h2>
            <form action="/admin/procedures/${procedure.id}" method="post" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>시술명<input name="name" value="${procedure.name?html}" required></label>
                <label>분류<input name="category" value="${procedure.category?html}"></label>
                <label>가격 (원)<input name="price" type="number" min="0" step="1" value="${procedure.price?string.computer}" required></label>
                <label>요약<input name="summary" value="${procedure.summary?html}" maxlength="160"></label>
                <label>상세 설명<textarea name="description" rows="6" maxlength="1000">${procedure.description?html}</textarea></label>
                <label class="check"><input type="checkbox" name="active" value="true"<#if procedure.active> checked</#if>> 판매중으로 노출</label>
                <div class="form-actions">
                    <button class="button" type="submit">저장</button>
                </div>
            </form>
        </div>
        <aside class="panel">
            <h2>현재 정보</h2>
            <dl class="summary-list">
                <div><dt>상품 번호</dt><dd>#${procedure.id}</dd></div>
                <div><dt>분류</dt><dd>${procedure.category?html}</dd></div>
                <div><dt>가격</dt><dd><strong>${numbers.formatInteger(procedure.price)}원</strong></dd></div>
                <div><dt>판매 상태</dt><dd>${procedure.active?then('판매중', '판매 중지')}</dd></div>
            </dl>
            <h2>상세 설명</h2>
            <div class="article-body">${procedure.description?html}</div>
        </aside>
    </section>
</main>
</body>
</html>
