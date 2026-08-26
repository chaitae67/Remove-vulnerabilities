<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>비밀번호 찾기</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">Find Password</p>
        <h1>비밀번호 찾기</h1>
        <#if error??><div class="flash error">${error}</div></#if>
        <#if message??><div class="flash success">${message}</div></#if>
        <form action="/forgot-password" method="post" class="stack-form">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input name="username" placeholder="아이디" required>
            <input name="email" type="email" placeholder="가입 시 등록한 이메일" required>
            <button class="button" type="submit">재설정 링크 받기</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
