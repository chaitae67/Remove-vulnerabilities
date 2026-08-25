<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>마이페이지</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/fragments/header.ftl">
<main>
    <section class="page-title">
        <p class="eyebrow">My Page</p>
        <h1>마이페이지</h1>
        <p>${user.name}님의 이용 내역입니다.</p>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>회원 정보</h2>
            <a href="/mypage/edit?userId=${user.id}">수정</a>
        </div>
        <article class="card">
            <p>아이디: <strong>${user.username}</strong></p>
            <p>이메일: <strong>${user.email}</strong></p>
            <p>연락처: <strong>${user.phone}</strong></p>
        </article>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>결제 내역</h2>
        </div>
        <ul class="board-list">
            <#list payments as payment>
            <li>
                <span>${payment.procedureProduct.name}</span>
                <span>${payment.amount?string("#,##0")}원</span>
                <span class="state">${payment.status}</span>
                <time>${payment.createdAt}</time>
            </li>
            </#list>
            <#if payments?size == 0>
            <li>
                <span>결제 내역이 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>내가 작성한 Q&amp;A</h2>
            <a href="/qna">more</a>
        </div>
        <ul class="board-list">
            <#list qnaPosts as post>
            <li>
                <a href="/qna/${post.id}">${post.title}</a>
                <span class="state">${post.answered?then('답변완료', '답변대기')}</span>
                <time>${post.createdAt}</time>
            </li>
            </#list>
            <#if qnaPosts?size == 0>
            <li>
                <span>작성한 글이 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>내가 작성한 후기</h2>
            <a href="/reviews">more</a>
        </div>
        <ul class="board-list">
            <#list myReviews as review>
            <li>
                <a href="/reviews/${review.id}">${review.title}</a>
                <span class="state"><#list 1..review.rating as i>★</#list></span>
                <time>${review.createdAt}</time>
            </li>
            </#list>
            <#if myReviews?size == 0>
            <li>
                <span>작성한 후기가 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>회원 탈퇴</h2>
        </div>
        <article class="card">
            <p class="muted">탈퇴 후에는 로그인할 수 없으며, 작성한 게시글과 결제 내역은 보관됩니다.</p>
            <#if withdrawError??>
            <p class="form-error">${withdrawError}</p>
            </#if>
            <form class="stack-form" action="/mypage/withdraw" method="post"
                  onsubmit="return confirm('정말 회원 탈퇴를 진행하시겠습니까?');">
                <label for="withdrawPassword">비밀번호 확인</label>
                <input id="withdrawPassword" name="password" type="password" required
                       autocomplete="current-password" placeholder="현재 비밀번호를 입력하세요">
                <button class="button button-outline" type="submit">회원 탈퇴</button>
            </form>
        </article>
    </section>
</main>
<#include "/fragments/footer.ftl">
</body>
</html>
