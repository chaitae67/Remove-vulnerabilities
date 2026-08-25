<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>제로데이클리닉</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>

<main>
    <section class="hero" aria-label="제로데이클리닉 의료진 소개">
        <img class="hero-image" src="/images/seohyun-main-hero.png"
             alt="성형의 기준을 세우다 - 정확한 진단, 안전한 수술, 독보적 결과">
    </section>

    <#if message??><div class="flash success">${message}</div></#if>
    <#if error??><div class="flash error">${error}</div></#if>

    <section class="content-band split">
        <div>
            <p class="eyebrow">Procedure Packages</p>
            <h2>상담 예약 결제</h2>
            <div class="product-grid">
                <#list procedures as procedure>
                <article class="card product-card">
                    <span class="tag">${procedure.category}</span>
                    <h3>${procedure.name}</h3>
                    <p>${procedure.summary}</p>
                    <strong>${numbers.formatInteger(procedure.price)}원</strong>
                    <a class="button button-small" href="/payments/checkout/${procedure.id}">예약 결제</a>
                </article>
                </#list>
            </div>
        </div>

        <aside class="quick-form">
            <p class="eyebrow">Quick Contact</p>
            <h2>빠른 비용 문의</h2>
            <form action="/consultations" method="post">
                <input name="name" placeholder="성함" required>
                <input name="phone" placeholder="휴대전화번호" required>
                <select name="area" required>
                    <option value="">희망 부위</option>
                    <option>지방흡입</option>
                    <option>윤곽/리프팅</option>
                    <option>눈/코</option>
                    <option>사후관리</option>
                </select>
                <select name="preferredContact" required>
                    <option>전화 상담</option>
                    <option>문자 안내</option>
                    <option>카카오톡 안내</option>
                </select>
                <textarea name="message" placeholder="궁금한 내용을 남겨주세요"></textarea>
                <label class="check"><input type="checkbox" name="privacyAgreed" value="true" required> 개인정보 수집 및 이용 동의</label>
                <button class="button" type="submit">상담신청</button>
            </form>
        </aside>
    </section>

    <section class="content-band columns">
        <div>
            <div class="section-head">
                <h2>공지사항</h2>
                <a href="/notices">more</a>
            </div>
            <form action="/notices/search" method="get" class="search-form">
                <input type="text" name="keyword" placeholder="공지 제목 검색">
                <button type="submit" class="button button-small">검색</button>
            </form>
            <ul class="board-list">
                <#list notices as notice>
                <li>
                    <a href="/notices/${notice.id}">${notice.title}</a>
                    <time>${temporals.format(notice.createdAt, 'MM-dd')}</time>
                </li>
                </#list>
            </ul>
        </div>
        <div>
            <div class="section-head">
                <h2>온라인 상담</h2>
                <a href="/qna">more</a>
            </div>
            <ul class="board-list">
                <#list qnas as post>
                <li>
                    <a href="/qna/${post.id}">${post.privatePost?then('비공개 상담글입니다', post.title)}</a>
                    <span class="state">${post.answered?then('답변완료', '대기')}</span>
                </li>
                </#list>
            </ul>
        </div>
    </section>
</main>

<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
