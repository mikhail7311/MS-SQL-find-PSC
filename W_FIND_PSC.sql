USE [Some_DB]
GO
/****** Object:  StoredProcedure [Shnurenko.M].[W_FIND_SCRCODE]    Script Date: 12/02/2009 15:33:54 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
ALTER   PROC  [Shnurenko.M].[W_FIND_SCRCODE]
----------------
-- Пересчитывает PSC на сотах перечисленных в db.[3G_CELL_reg] -- выборка из МапИнфо
----------------
AS

DECLARE 
@SCR_CODE smallint,
@oFWC_NAME VARCHAR(30),
@count smallint,
@c smallint

--очистка итоговой таблицы: 
DELETE FROM db.W_CELL_PSC_reg

--------------------------
-- заполнение временной таблицы текущими данными по установленным PSC на работающих секторах
-- таблица [Shnurenko.M].Curent_PSC заполняется отдельной процедурой, 
-- подготавливающей сырые данные для импользования здесь 
-- [Shnurenko.M].Curent_PSC состоит из полей LONGITUDE , LATITUDE , WC_NAME, WC_PRISCRCOD

SELECT * 
	into #BDKS
	from [Shnurenko.M].Curent_PSC 

-- проверка на наличие записей в таблице сот для пересчета db.[3G_CELL_reg]
select @c = COUNT(*)
From 
(SELECT WC_NAME from #BDKS) d
inner join
(SELECT W_CELL from db.[3G_CELL_reg]) g 
on d.WC_NAME = g.W_CELL	COLLATE latin1_general_cs_as

-- если выборка пустая, то на выход (актуально при расчете по секторам)
if @c = 0 GOTO lab
-- иначе начинается пересчет на выбранных сотах из db.[3G_CELL_reg]
---------------------------

--Загрузка данных по парам секторов и дистанции между ними во временную таблицу #tWCELL_DIST
select	a1.WC_NAME COLLATE latin1_general_cs_as as FWC_NAME,
	a2.WC_NAME COLLATE latin1_general_cs_as as SWCNAME,
	a1.WC_PRISCRCODE AS F_PRISCODE, a2.WC_PRISCRCODE AS S_PRISCODE,
	(2*6356863 
	*asin(sqrt	( 
		((sin(0.5*(a1.latitude_1-a2.latitude_2)*pi()/180))*(sin(0.5*(a1.latitude_1-a2.latitude_2)*pi()/180)))  
		+ cos(a1.latitude_1*pi()/180)*cos(a2.latitude_2*pi()/180)
		*((sin(0.5*(a1.longitude_1-a2.longitude_2)*pi()/180))*(sin(0.5*(a1.longitude_1-a2.longitude_2)*pi()/180))) 
				)) 
		   ) as DIST -- distance in meters
 into #tWCELL_DIST
from 	(select distinct WC_NAME, LATITUDE as latitude_1, LONGITUDE as longitude_1,WC_PRISCRCODE
	-- coordinates of first site
	from #BDKS
			) as a1,
	(select distinct WC_NAME, LATITUDE as latitude_2, LONGITUDE as longitude_2,WC_PRISCRCODE
	-- coordinates of second site
	from #BDKS
			) as a2
-- заполнение временной таблицы #regCell секторами для пересчета PSC
Select * 
into #regCell
from db.[3G_CELL_reg]


-- блок отбора подходящих PSC
-- цикл с поиском в выбранной области сектора, ближайшего к секторам из внешней области, 
-- расчет для него оптимального PSC и исключение сектора из #regCell
-- цикл до тех пор, пока #regCell не опустеет

WHILE -- пока пересечение таблиц не пустое (#regCell не пустая)
(Select COUNT (FWC_NAME) FROM 
	#tWCELL_DIST od
	inner join
	#regCell reg
	on od.FWC_NAME = reg.W_CELL COLLATE latin1_general_cs_as
	where od.S_PRISCODE is not null 
) > 0
BEGIN --++++++++++vvvvvvvvvv++++++++++
-- 1. Выбор сектора наиболее близкого к секторам вне данного множества @oFWC_NAME
SELECT @oFWC_NAME = FWC_NAME -- сектор из выбранной области, ближайший к сектору в внешней области
FROM 
	#tWCELL_DIST cd
inner join
	(SELECT Min(dis.DIST) as MinOfDIST -- минимальная дистанция между объектом из выбранной области и вне ее
	-- выбор из #tWCELL_DIST записей у которых FWC_NAME содержится в #regCell, а SWCNAME нет
	FROM #tWCELL_DIST dis
	inner join
		#regCell reg
	on dis.FWC_NAME = reg.W_CELL COLLATE latin1_general_cs_as
	left join
		#regCell noreg
	on dis.SWCNAME = noreg.W_CELL COLLATE latin1_general_cs_as
	WHERE noreg.W_CELL is null 
			and dis.S_PRISCODE is not null 
	)d
on cd.DIST = d.MinOfDIST 
and cd.FWC_NAME COLLATE latin1_general_cs_as in (SELECT W_CELL from #regCell)

-- 2. Загрузка в #PSC_MINDIST всех PSC и минимальных расстояний от секторов с ними до @oFWC_NAME
Select S_PRISCODE, min(DIST)as MINDIST 
into #PSC_MINDIST
FROM 
#tWCELL_DIST od
left join
#regCell noreg
on od.SWCNAME = noreg.W_CELL COLLATE latin1_general_cs_as
WHERE noreg.W_CELL is null 
		and od.S_PRISCODE is not null 
		and od.FWC_NAME = @oFWC_NAME COLLATE latin1_general_cs_as
GROUP BY S_PRISCODE

Set @count = ( Select count (S_PRISCODE) FROM #PSC_MINDIST)
-- vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv
-- 3. Выбор PSC из #PSC_MINDIST с максимальным расстоянием от @oFWC_NAME
IF @count < 512 -- если в #PSC_MINDIST присутствуют НЕ все PSC из возможных
BEGIN
	SET @SCR_CODE = 0
	WHILE (Select count (S_PRISCODE) FROM #PSC_MINDIST
			Where  S_PRISCODE = @SCR_CODE) > 0 -- пока не найдем отсутствующий PSC 
			OR @SCR_CODE >= 512 -- или не превысим максимально возможный PSC
		BEGIN
			SET @SCR_CODE = @SCR_CODE + 1
		END
END
ELSE	-- если в #PSC_MINDIST присутствуют все PSC из выбранного диапазона
BEGIN
	SET @SCR_CODE = (SELECT min(S_PRISCODE) 
		FROM
			#PSC_MINDIST psc
		inner join
			(SELECT MAX (MINDIST) as maxmin FROM #PSC_MINDIST) distan -- дистанция до сектора с которого буду брать PSC
		on psc.MINDIST = distan.maxmin
		)
END
-- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
-- 4. подходящий PSC сохранен в @SCR_CODE, удаляю таблицу #PSC_MINDIST с PSC и расстояниями от @oFWC_NAME до ближайшего сектора с таким же PSC
drop table #PSC_MINDIST

-- 5. Обновление данных в #tWCELL_DIST с учетом вновь подобранного PSC для выбранной соты:
UPDATE #tWCELL_DIST
SET F_PRISCODE = @SCR_CODE
WHERE FWC_NAME = @oFWC_NAME

UPDATE #tWCELL_DIST
SET S_PRISCODE = @SCR_CODE
WHERE SWCNAME = @oFWC_NAME

INSERT INTO db.W_CELL_PSC_reg
	   VALUES (@oFWC_NAME,@SCR_CODE) 

-- 6. Удаляю просчитанный сектор из #regCell
DELETE FROM #regCell
WHERE W_CELL = @oFWC_NAME
-- возвращаюсь в начало цикла
END --++++++++++^^^^^^^^^^++++++++++

-- удаляю временные таблицы
drop table #regCell
drop table #tWCELL_DIST
lab: 
drop table #BDKS
