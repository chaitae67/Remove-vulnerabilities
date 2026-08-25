<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>마이페이지</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="mypage-page">
    <section class="mypage-hero">
        <p class="eyebrow">My Page</p>
        <h1><strong>${user.name}</strong>님,<br>반갑습니다.</h1>
        <p>예약과 상담, 작성하신 후기를 한곳에서 편하게 확인하세요.</p>
    </section>

    <section class="mypage-dashboard">
      <aside class="mypage-profile">
        <div class="profile-monogram">${user.name?substring(0, 1)}</div>
        <p class="eyebrow">Member Profile</p>
        <h2>${user.name}</h2>
        <dl><div><dt>아이디</dt><dd>${user.username}</dd></div><div><dt>이메일</dt><dd>${user.email}</dd></div><div><dt>연락처</dt><dd>${user.phone!'-'}</dd></div></dl>
        <a class="profile-edit-link" href="/mypage/edit?userId=${user.id}">회원정보 수정 <span>→</span></a>
      </aside>
      <div class="mypage-main">
        <div class="mypage-summary">
            <a href="#payments"><span>PAYMENT</span><strong>${payments?size}</strong><small>결제 내역</small></a>
            <a href="#my-qna"><span>CONSULT</span><strong>${qnaPosts?size}</strong><small>작성한 상담</small></a>
            <a href="#my-reviews"><span>REVIEW</span><strong>${myReviews?size}</strong><small>작성한 후기</small></a>
        </div>

    <section id="payments" class="mypage-section">
        <div class="section-head">
            <h2>결제 내역</h2>
        </div>
        <ul class="board-list">
            <#list payments as payment>
            <li>
                <span>${payment.procedureProduct.name}</span>
                <span>${numbers.formatInteger(payment.amount)}원</span>
                <span class="state">${payment.status}</span>
                <time>${temporals.format(payment.createdAt, 'yyyy-MM-dd HH:mm')}</time>
            </li>
            </#list>
            <#if payments?size == 0>
            <li>
                <span>결제 내역이 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>

    <section id="my-qna" class="mypage-section">
        <div class="section-head">
            <h2>내가 작성한 Q&amp;A</h2>
            <a href="/qna">more</a>
        </div>
        <ul class="board-list">
            <#list qnaPosts as post>
            <li>
                <a href="/qna/${post.id}">${post.title}</a>
                <span class="state">${post.answered?then('답변완료', '답변대기')}</span>
                <time>${temporals.format(post.createdAt, 'yyyy-MM-dd')}</time>
            </li>
            </#list>
            <#if qnaPosts?size == 0>
            <li>
                <span>작성한 글이 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>

    <section id="my-reviews" class="mypage-section">
        <div class="section-head">
            <h2>내가 작성한 후기</h2>
            <a href="/reviews">more</a>
        </div>
        <ul class="board-list">
            <#list myReviews as review>
            <li>
                <a href="/reviews/${review.id}">${review.title}</a>
                <span class="state">${strings.repeat("★", review.rating)}</span>
                <time>${temporals.format(review.createdAt, 'yyyy-MM-dd')}</time>
            </li>
            </#list>
            <#if myReviews?size == 0>
            <li>
                <span>작성한 후기가 없습니다.</span>
            </li>
            </#if>
        </ul>
    </section>

    <section class="mypage-section withdraw-section">
        <div class="section-head">
            <h2>회원 탈퇴</h2>
        </div>
        <article class="card">
            <p class="muted">탈퇴 후에는 로그인할 수 없으며, 작성한 게시글과 결제 내역은 보관됩니다.</p>
            <#if withdrawError??><p class="form-error">${withdrawError}</p></#if>
            <form class="stack-form" action="/mypage/withdraw" method="post"
                  onsubmit="return confirm('정말 회원 탈퇴를 진행하시겠습니까?');">
                <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
                <label for="withdrawPassword">비밀번호 확인</label>
                <input id="withdrawPassword" name="password" type="password" required
                       autocomplete="current-password" placeholder="현재 비밀번호를 입력하세요">
                <button class="button button-outline" type="submit">회원 탈퇴</button>
            </form>
        </article>
    </section>
      </div>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
