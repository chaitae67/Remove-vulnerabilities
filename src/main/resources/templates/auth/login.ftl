<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>로그인</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">Member Login</p>
        <h1>로그인</h1>
        <#if message??>
        <div class="flash success">${message}</div>
        </#if>
        <#if error??>
        <div class="flash error">아이디 또는 비밀번호를 확인해 주세요.</div>
        </#if>
        <form action="/login" method="post" class="stack-form">
            <input name="username" placeholder="아이디" required>
            <input name="password" type="password" placeholder="비밀번호" required>
            <button class="button" type="submit">로그인</button>
        </form>
        <p class="muted">테스트 계정: admin / admin1234, user / user1234</p>
        <p class="muted"><a href="/forgot-password">비밀번호 찾기</a></p>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
