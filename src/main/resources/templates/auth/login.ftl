<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>로그인</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">Member Login</p>
        <h1>로그인</h1>
        <#if message??><div class="flash success">${message}</div></#if>
        <#if param.error??><div class="flash error">아이디 또는 비밀번호를 확인해 주세요.</div></#if>
        <form action="/login" method="post" class="stack-form">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input name="username" placeholder="아이디" required>
            <input name="password" type="password" placeholder="비밀번호" required>
            <button class="button" type="submit">로그인</button>
        </form>
        <p class="muted">테스트 계정: admin / admin1234, user / user1234</p>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
