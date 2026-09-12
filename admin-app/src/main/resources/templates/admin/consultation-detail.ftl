<#assign navActive = "consultations">
<#assign contactOptions = ["전화", "문자", "카카오톡", "이메일"]>
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>상담 신청 상세 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page admin-detail">
    <section class="page-title">
        <p class="eyebrow">CONSULTATION #${consultation.id}</p>
        <h1>${consultation.name?html} 님의 상담 신청</h1>
        <p><a class="back-link" href="/admin/consultations">← 상담 신청 목록</a></p>
    </section>

    <section class="content-band admin-detail-grid">
        <div class="panel">
            <h2>신청 정보 수정</h2>
            <form action="/admin/consultations/${consultation.id}" method="post" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>신청자 이름<input name="name" value="${consultation.name?html}" required></label>
                <label>연락처<input name="phone" value="${consultation.phone?html}" required></label>
                <label>관심 부위<input name="area" value="${consultation.area?html}"></label>
                <label>선호 연락 방법
                    <select name="preferredContact">
                        <#list contactOptions as option>
                        <option value="${option}"<#if consultation.preferredContact == option> selected</#if>>${option}</option>
                        </#list>
                        <#if !contactOptions?seq_contains(consultation.preferredContact)>
                        <option value="${consultation.preferredContact?html}" selected>${consultation.preferredContact?html}</option>
                        </#if>
                    </select>
                </label>
                <label>희망 날짜<input name="preferredDate" type="date" value="<#if consultation.preferredDate??>${temporals.format(consultation.preferredDate, 'yyyy-MM-dd')}</#if>"></label>
                <label>상담 내용<textarea name="message" rows="5">${(consultation.message!'')?html}</textarea></label>
                <label>특이사항 (관리자 메모)<textarea name="adminNote" rows="4" placeholder="응대 내역, 주의사항 등을 기록하세요.">${(consultation.adminNote!'')?html}</textarea></label>
                <div class="form-actions">
                    <button class="button" type="submit">저장</button>
                </div>
            </form>
            <form action="/admin/consultations/${consultation.id}/delete" method="post" class="danger-form" onsubmit="return confirm('이 상담 신청을 삭제하시겠습니까? 되돌릴 수 없습니다.');">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <button class="button button-danger" type="submit">상담 신청 삭제</button>
            </form>
        </div>
        <aside class="panel">
            <h2>접수 정보</h2>
            <dl class="summary-list">
                <div><dt>접수 번호</dt><dd>#${consultation.id}</dd></div>
                <div><dt>신청 일시</dt><dd>${temporals.format(consultation.createdAt, 'yyyy.MM.dd HH:mm')}</dd></div>
                <div><dt>개인정보 동의</dt><dd>${consultation.privacyAgreed?then('동의함', '미동의')}</dd></div>
                <div><dt>희망 날짜</dt><dd><#if consultation.preferredDate??>${temporals.format(consultation.preferredDate, 'yyyy.MM.dd')}<#else>미지정</#if></dd></div>
            </dl>
            <h2>상담 내용</h2>
            <div class="article-body"><#if consultation.message?has_content>${consultation.message?html}<#else><span class="muted">작성된 내용이 없습니다.</span></#if></div>
            <h2>특이사항</h2>
            <div class="article-body"><#if consultation.adminNote?has_content>${consultation.adminNote?html}<#else><span class="muted">등록된 메모가 없습니다.</span></#if></div>
        </aside>
    </section>
</main>
</body>
</html>
