<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>온라인 상담</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main>
    <section class="page-title with-action">
        <div>
            <p class="eyebrow">Q&A</p>
            <h1>온라인 상담</h1>
            <p>로그인 후 사진 또는 문서를 첨부해 상담 글을 남길 수 있습니다.</p>
        </div>
        <a class="button" href="/qna/new">상담 작성</a>
    </section>
    <#if message??><div class="flash success">${message}</div></#if>
    <section class="content-band">
        <ul class="table-list">
            <#list posts as post>
            <li>
                <a href="/qna/${post.id}">${post.privatePost?then('비공개 상담글입니다', post.title)}</a>
                <span>${post.answered?then('답변완료', '대기')}</span>
                <time>${temporals.format(post.createdAt, 'yyyy.MM.dd')}</time>
            </li>
            </#list>
        </ul>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
