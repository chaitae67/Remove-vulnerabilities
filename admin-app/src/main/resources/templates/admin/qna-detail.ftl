<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Q&A 관리</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<main class="content-band" style="max-width:900px;margin:40px auto;">
    <p><a href="/admin">← 관리자 대시보드</a></p>
    <section class="panel">
        <p class="eyebrow">Q&A MANAGEMENT</p>
        <h1>${post.title}</h1>
        <p>작성자: ${post.writer.username} / 연락처: ${(post.phone)!'-'}</p>
        <div class="prose">${post.content}</div>
        <hr>
        <#if post.answered>
            <h2>현재 답변</h2>
            <div class="prose">${post.answer!''}</div>
        </#if>
        <form action="/admin/qna/${post.id}/answer" method="post" class="stack-form">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <label>관리자 답변<textarea name="answer" rows="8" required>${post.answer!''}</textarea></label>
            <button class="button" type="submit">답변 저장</button>
        </form>
        <form action="/admin/qna/${post.id}/delete" method="post" onsubmit="return confirm('삭제하시겠습니까?');">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <button class="button button-danger" type="submit">Q&A 삭제</button>
        </form>
    </section>
</main>
</body>
</html>
