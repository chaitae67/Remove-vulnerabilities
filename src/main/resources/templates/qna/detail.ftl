<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${post.title}</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow-wide">
    <#if message??>
    <div class="flash success">${message}</div>
    </#if>
    <article class="panel article">
        <p class="eyebrow">Online Q&A</p>
        <h1><#if post.privatePost && !canReadPrivate>비공개 상담글입니다<#else>${post.title}</#if></h1>
        <p class="muted">${post.writer.name} · ${post.createdAt}</p>

        <#if canReadPrivate>
        <div>
            <div class="article-body">${post.content}</div>
            <#if post.attachments?size > 0>
            <div class="attachments">
                <h2>첨부파일</h2>
                <#list post.attachments as file>
                <a href="/qna/download?filename=${file.storedFilename}" target="_blank">${file.originalFilename}</a>
                </#list>
            </div>
            </#if>
            <#if post.answered>
            <section class="answer-box">
                <span class="tag">답변완료</span>
                <p>${post.answer}</p>
            </section>
            <#else>
            <section class="answer-box muted-box">
                <span class="tag">대기</span>
                <p>관리자 답변을 기다리고 있습니다.</p>
            </section>
            </#if>
        </div>
        <#else>
        <div class="article-body">
            작성자와 관리자만 볼 수 있는 상담 내용입니다.
        </div>
        </#if>

        <#if canAnswer>
        <form class="stack-form answer-form" action="/qna/${post.id}/answer" method="post">
            <textarea name="answer" rows="6" placeholder="관리자 답변" required>${post.answer}</textarea>
            <button class="button" type="submit">답변 저장</button>
        </form>
        </#if>

        <div class="actions">
            <a class="button button-outline" href="/qna">목록</a>
        </div>
    </article>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
