<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>비밀번호 찾기</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">Password Reset</p>
        <h1>비밀번호 찾기</h1>
        <#if error??>
        <div class="flash error">${error}</div>
        </#if>
        <form action="/forgot-password" method="post" class="stack-form">
            <input name="username" placeholder="아이디" required>
            <button class="button" type="submit">인증번호 발급</button>
        </form>
        <#if issuedCode??>
        <div class="flash success">인증번호: ${issuedCode}</div>
        </#if>
        <#if username??>
        <form action="/forgot-password/reset" method="post" class="stack-form">
            <input type="hidden" name="username" value="${username}">
            <input name="code" placeholder="인증번호(4자리)" required maxlength="4">
            <input name="newPassword" type="password" placeholder="새 비밀번호" required>
            <button class="button" type="submit">비밀번호 변경</button>
        </form>
        </#if>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
