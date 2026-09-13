<#assign navActive = "qna">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Q&A 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page admin-detail">
    <section class="page-title">
        <p class="eyebrow">Q&amp;A #${post.id}</p>
        <#-- (실습용) 제목/본문/답변은 원본 그대로 출력한다. -->
        <h1>${post.title}</h1>
        <p><a class="back-link" href="/admin/qna">← Q&amp;A 목록</a></p>
    </section>

    <section class="content-band">
        <div class="panel">
            <dl class="summary-list">
                <div><dt>작성자</dt><dd>${post.writer.name} (@${post.writer.username})</dd></div>
                <div><dt>연락처</dt><dd>${(post.phone)!'-'}</dd></div>
                <div><dt>공개 여부</dt><dd>${post.privatePost?then('비공개', '공개')}</dd></div>
                <div><dt>작성일</dt><dd>${temporals.format(post.createdAt, 'yyyy.MM.dd HH:mm')}</dd></div>
                <div><dt>답변 상태</dt><dd><#if post.answered>답변완료<#if post.answeredAt??> · ${temporals.format(post.answeredAt, 'yyyy.MM.dd HH:mm')}</#if><#else>대기</#if></dd></div>
            </dl>
            <h2>문의 내용</h2>
            <div class="prose">${post.content}</div>
            <#if post.answered>
            <h2>현재 답변</h2>
            <div class="prose">${post.answer!''}</div>
            </#if>
        </div>
    </section>

    <section class="content-band">
        <div class="panel">
            <h2>관리자 답변</h2>
            <form action="/admin/qna/${post.id}/answer" method="post" class="stack-form">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label>답변 내용<textarea name="answer" rows="8" required>${post.answer!''}</textarea></label>
                <div class="form-actions">
                    <button class="button" type="submit">답변 저장</button>
                </div>
            </form>
            <form action="/admin/qna/${post.id}/delete" method="post" class="danger-form" onsubmit="return confirm('이 상담 글을 삭제하시겠습니까? 되돌릴 수 없습니다.');">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <button class="button button-danger" type="submit">Q&amp;A 삭제</button>
            </form>
        </div>
    </section>
</main>
</body>
</html>
