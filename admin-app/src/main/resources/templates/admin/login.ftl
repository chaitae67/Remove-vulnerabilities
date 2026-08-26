<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zero Day Clinic 관리자 로그인</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<main class="content-band" style="max-width:520px;margin:80px auto;">
    <section class="panel">
        <p class="eyebrow">ADMIN</p>
        <h1>관리자 로그인</h1>
        <#if error??>
            <div class="flash error">아이디 또는 비밀번호를 확인해 주세요.</div>
        </#if>
        <#if logout??>
            <div class="flash success">로그아웃되었습니다.</div>
        </#if>
        <form action="/login" method="post" class="stack-form">
            <label>아이디<input type="text" name="username" autocomplete="username" required></label>
            <label>비밀번호<input type="password" name="password" autocomplete="current-password" required></label>
            <button class="button" type="submit">관리자 로그인</button>
        </form>
    </section>
</main>
</body>
</html>
