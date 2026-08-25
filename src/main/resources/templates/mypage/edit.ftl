<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>회원정보 수정</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">My Page</p>
        <h1>회원정보 수정</h1>
        <p class="muted">${user.name}님, 정보를 최신 상태로 유지해 주세요.</p>

        <form action="/mypage/edit" method="post" class="stack-form profile-form">
            <input type="hidden" name="userId" value="${user.id}">

            <label class="field">
                <span>아이디</span>
                <input type="text" value="${user.username}" disabled>
            </label>

            <label class="field">
                <span>이름</span>
                <input type="text" name="name" value="${user.name}" required>
            </label>

            <label class="field">
                <span>이메일</span>
                <input type="email" name="email" value="${user.email}" required>
            </label>

            <label class="field">
                <span>연락처</span>
                <input type="text" name="phone" value="${user.phone}" placeholder="010-0000-0000">
            </label>

            <div class="profile-actions">
                <a class="button button-outline" href="/mypage?userId=${user.id}">취소</a>
                <button class="button" type="submit">저장하기</button>
            </div>
        </form>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
